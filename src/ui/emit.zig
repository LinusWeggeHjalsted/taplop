//! Shared panel-builder primitives: the emit helpers every builder uses —
//! panel headers, icon/panel/skill buttons, centered + corner number
//! labels — plus the skill-slot Action mapping. Pure element-list
//! appends over element.zig vocabulary; no game-state reads.

const std = @import("std");
const types = @import("../types.zig");
const element = @import("element.zig");
const lookups = @import("../generated_lookups.zig");
const Effect = @import("../effect.zig").Effect;
const ui_tooltip = @import("tooltip.zig");

const Action = types.Action;
const Rectangle = types.Rectangle;
const Color = types.Color;
const ScreenPosition = types.ScreenPosition;
const Span = element.Span;
const Tooltip = element.Tooltip;
const TooltipRow = element.TooltipRow;
const text = element.text;
const colored = element.colored;
const bold = element.bold;
const FontMetrics = element.FontMetrics;
const UiElement = element.UiElement;
const UiElementList = element.UiElementList;
const Button = element.Button;
const TextLabel = element.TextLabel;
const Image = element.Image;
const slot_size = element.slot_size;
const ui_gap = element.ui_gap;
const slot_padding = element.slot_padding;
const small_icon_size = element.small_icon_size;
const panel_button_height = element.panel_button_height;
const middle_panel_header_height = element.middle_panel_header_height;
const middle_panel_header_font_size = element.middle_panel_header_font_size;
const close_button_sprite_id = element.close_button_sprite_id;
const close_button_size = element.close_button_size;
const SlotRef = element.SlotRef;
const Entity = types.Entity;
const SkillId = types.SkillId;
const spanRow = @import("tooltip.zig").spanRow;
const buildSkillTooltip = ui_tooltip.buildSkillTooltip;
const EquippedGear = ui_tooltip.EquippedGear;
const positive_color = ui_tooltip.positive_color;
const negative_color = ui_tooltip.negative_color;
const isSkillLearnedIn = ui_tooltip.isSkillLearnedIn;
const weapon_type_count = @typeInfo(types.WeaponType).@"enum".fields.len;
const WeaponTypeDefinition = types.WeaponTypeDefinition;

/// Font size of the material-count corner label on item icons (bottom bar,
/// inventory, pickers) — shared with the editor material icons.
pub const material_count_font_size: i32 = 48;

/// Inset of the material-count corner label from the icon's edge.
pub const material_count_inset: i32 = 8;

pub const cooldown_font_size: i32 = 96;
pub const overlay_font_size: i32 = 64;

/// Emit a centered integer label inside `cell` (cooldowns, momentum,
/// effect durations). Centered on the MEASURED text width via `font_metrics`
/// so multi-digit numbers sit truly centered; vertical centering uses the
/// `font_size` glyph cell (raylib draws from the top of that cell).
pub fn emitCenteredNumber(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    value: u32,
    font_size: i32,
) !void {
    const label = try std.fmt.allocPrint(allocator, "{d}", .{value});
    // Center on the MEASURED text width (not a font_size square) so multi-digit
    // numbers sit truly centered. Vertical centering uses the `font_size` glyph
    // cell (not `lineHeight`) — raylib draws a glyph from the top of a
    // font_size-tall cell, so centering that cell puts the visual mass on the
    // button's center; centering the taller lineHeight box would sit text high.
    const label_width = font_metrics.measureSpanWidth(text(label), font_size);
    const label_box = cell.placeCenter(label_width, font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = label_box.position(),
        .font_size = font_size,
        // Outlined for readability over varied icon art.
        .outlined = true,
        // Sits on top of its parent icon/button; let its tooltip win the hover.
        .blocks_input = false,
    } });
}

/// Emit a number label in the BOTTOM-RIGHT corner of `cell`, outlined for
/// readability. Mirrors the material-count placement (`material_count_font_size`
/// + `material_count_inset`) so effect-duration numbers read like the
/// inventory material counts. Used for active-effect duration overlays.
pub fn emitCornerNumber(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    value: u32,
) !void {
    const label = try std.fmt.allocPrint(allocator, "{d}", .{value});
    const label_width = font_metrics.measureSpanWidth(text(label), material_count_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = .{
            .x = cell.x + cell.width - label_width - material_count_inset,
            .y = cell.y + cell.height - material_count_font_size - material_count_inset,
        },
        .font_size = material_count_font_size,
        .outlined = true,
        .blocks_input = false,
    } });
}

/// Sprite id of the reusable button background — a rounded panel drawn
/// under an icon so the coloring framework can tint background and icon
/// independently.
pub const button_background_sprite_id: []const u8 = "ui/button_background";

/// Emit a middle-panel header: a title `text_label` on the left (vertically
/// centered in the `header_height` strip) + a close `button` flush in the
/// panel's top-right corner. Returns the content bounds — the area below the
/// header where the panel body lives. The close button carries the panel's
/// toggle action (firing it while open closes the panel); the view() hover
/// pass sets `highlighted` on the button under the pointer, so the renderer
/// rings it with the theme lightest. Callers emit the 9-slice panel
/// background first, then this, then position body elements within the
/// returned content bounds.
pub fn emitPanelHeader(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    bounds: Rectangle,
    title: []const u8,
    close_action: Action,
) !Rectangle {
    const origin = bounds.position();
    // raylib draws a glyph from the top of a font_size-tall cell, so offset
    // by (header_height − font_size)/2 to center the visual mass.
    const text_y = origin.y + @divFloor(middle_panel_header_height - middle_panel_header_font_size, 2);
    try elements.append(allocator, .{ .text_label = .{
        .text = title,
        .screen_position = .{ .x = origin.x + ui_gap, .y = text_y },
        .font_size = middle_panel_header_font_size,
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
        .action = close_action,
    } });
    return .{
        .x = bounds.x,
        .y = bounds.y + middle_panel_header_height,
        .width = bounds.width,
        .height = bounds.height - middle_panel_header_height,
    };
}

/// Emit a layered icon button: a background sprite (carries the action,
/// tooltip, and hit-test) with the icon drawn on top. The icon passes hover
/// through to the background so the whole button is one target. Callers pass
/// the background id so different button styles (bottom-bar frame, skill
/// frame) reuse the same layering.
pub fn emitIconButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    cell: Rectangle,
    background_sprite_id: []const u8,
    icon_sprite_id: []const u8,
    action: Action,
    tooltip: ?Tooltip,
    background_color: Color,
    icon_color: Color,
    highlighted: bool,
    /// Drag ref, if this button is also a drag source/drop target.
    ref: ?SlotRef,
) !void {
    try elements.append(allocator, .{ .button = .{
        .sprite_id = background_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = action,
        .color = background_color,
        .tooltip = tooltip,
        .highlighted = highlighted,
        .ref = ref,
    } });
    try elements.append(allocator, .{ .image = .{
        .sprite_id = icon_sprite_id,
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = icon_color,
        // Sits on top of the background; let the button win the hit-test.
        .blocks_input = false,
    } });
}

/// Emit a panel-backed button: a 9-slice panel background, a spriteless
/// Button over it (owns the action + hit-test + optional tooltip), and a
/// centered text label on top. Used for text buttons (main menu, settings,
/// dialog choices).
pub fn emitPanelButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    label: []const u8,
    font_size: i32,
    action: Action,
    button_color: Color,
    tooltip: ?Tooltip,
) !void {
    // Button panels take an explicit tint (player gradient index 5) so they
    // read as buttons against background panels, which stay theme `darkest`.
    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = "ui/panel",
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .color = button_color,
    } });
    try elements.append(allocator, .{ .button = .{
        .screen_position = cell.position(),
        .width = cell.width,
        .height = cell.height,
        .action = action,
        .tooltip = tooltip,
    } });
    // Centered label. Horizontal centering uses the measurement seam;
    // vertical centering uses the `font_size` glyph cell (not `lineHeight`) —
    // raylib draws from the top of a font_size-tall cell, so centering that
    // cell (not the taller lineHeight box) puts the visual mass on the
    // button's center.
    const label_width = font_metrics.measureSpanWidth(text(label), font_size);
    const label_box = cell.placeCenter(label_width, font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = label,
        .screen_position = label_box.position(),
        .font_size = font_size,
        // Sits on top of the button; let the button win the hit-test.
        .blocks_input = false,
    } });
}

/// Map a skill bar slot (1-8) to its input Action, so clicking a skill
/// button triggers the same path as the keybind.
pub fn skillSlotAction(slot: u8) Action {
    return switch (slot) {
        1 => .skill_slot_1,
        2 => .skill_slot_2,
        3 => .skill_slot_3,
        4 => .skill_slot_4,
        5 => .skill_slot_5,
        6 => .skill_slot_6,
        7 => .skill_slot_7,
        8 => .skill_slot_8,
        else => unreachable,
    };
}

/// Inverse of `skillSlotAction`: map a skill-slot Action back to its slot
/// number (1-8), or null for any other action. Used by `view()` to detect
/// when the pointer hovers a skill button and resolve which skill it is.
pub fn actionSkillSlot(action: Action) ?u8 {
    return switch (action) {
        .skill_slot_1 => 1,
        .skill_slot_2 => 2,
        .skill_slot_3 => 3,
        .skill_slot_4 => 4,
        .skill_slot_5 => 5,
        .skill_slot_6 => 6,
        .skill_slot_7 => 7,
        .skill_slot_8 => 8,
        else => null,
    };
}

/// Emit one skill button into `cell`. If the slot resolves to a skill,
/// draws the icon button (with tooltip) plus a cooldown overlay and
/// remaining-turns number when on cooldown. Empty slots (e.g. a missing
/// off-hand weapon) draw an empty-slot placeholder so the row keeps its
/// width.
pub fn emitSkillButton(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell: Rectangle,
    slot: u8,
    player: Entity,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    background_color: Color,
    icon_color: Color,
    prepared_skill: ?SkillId,
    /// Tint for the cooldown overlay (the skill-button sprite washed at 50%
    /// alpha). Caller passes the active theme's darkest color.
    cooldown_overlay_color: Color,
    /// Drag ref for this slot, if it's a reorderable utility slot. Null for
    /// weapon-skill slots (1-3, derived from the equipped weapon — not
    /// draggable). Set by the caller for utility slots 4-8.
    drag_ref: ?SlotRef,
    /// The slot currently being dragged from, if any. The source slot renders
    /// empty (diamond) so the skill reads as "in flight" (shown only as the
    /// ghost following the pointer).
    drag_source: ?SlotRef,
) !void {
    const skill_id = player.skillInSlot(slot, weapon_type_definitions);
    const definition = if (skill_id) |id| lookups.getSkillDefinition(id) else null;
    const is_drag_source = blk: {
        // A ref-less slot (weapon skill) can never be the drag source.
        const ref = drag_ref orelse break :blk false;
        const src = drag_source orelse break :blk false;
        break :blk src.eql(ref);
    };

    // Empty, or the drag source (skill is "in flight"): render the diamond
    // marker. For a reorderable utility slot this is a `.slot` carrying the
    // ref so it stays a DROP TARGET (an empty slot can receive a drop). For
    // a weapon slot or the drag source it's a plain `.image` (inert — no
    // ref, no action; a same-slot drop is already a no-op via the guard).
    if (skill_id == null or definition == null or is_drag_source) {
        if (drag_ref) |ref| {
            try elements.append(allocator, .{ .slot = .{
                .screen_position = cell.position(),
                .size = cell.width,
                .icon_sprite_id = "ui/skill_slot_empty",
                .icon_color = background_color,
                .ref = ref,
            } });
        } else {
            try elements.append(allocator, .{ .image = .{
                .sprite_id = "ui/skill_slot_empty",
                .screen_position = cell.position(),
                .width = cell.width,
                .height = cell.height,
                .color = background_color,
            } });
        }
        return;
    }

    // Filled slot: skill frame background + the skill's icon on top. The icon
    // id mirrors the SkillId tag name (assets/skills/<tag>.png). Highlighted
    // when this slot holds the prepared skill awaiting target confirmation.
    const is_prepared = prepared_skill != null and prepared_skill.? == skill_id.?;
    const icon_sprite_id = skillIconSpriteId(skill_id.?);
    try emitIconButton(
        elements,
        allocator,
        cell,
        "ui/skill_button",
        icon_sprite_id,
        skillSlotAction(slot),
        try buildSkillTooltip(allocator, definition.?),
        background_color,
        icon_color,
        is_prepared,
        drag_ref,
    );

    const cooldown = player.skill_cooldowns.get(skill_id.?);
    if (cooldown > 0) {
        try elements.append(allocator, .{ .image = .{
            // Reuse the skill-button frame as a translucent wash so the icon
            // reads as dimmed/locked. Tinted darkest theme color at 50% alpha.
            .sprite_id = "ui/skill_button",
            .screen_position = cell.position(),
            .width = cell.width,
            .height = cell.height,
            .color = cooldown_overlay_color,
            .alpha = 128,
            // Overlay on the skill button — pass hover through to the button.
            .blocks_input = false,
        } });
        try emitCenteredNumber(elements, allocator, font_metrics, cell, cooldown, cooldown_font_size);
    }
}

/// returned slice is stable for the process lifetime (no allocation) —
/// drag ghosts borrow it across frames.
pub fn skillIconSpriteId(skill_id: SkillId) []const u8 {
    const table = comptime blk: {
        const fields = @typeInfo(SkillId).@"enum".fields;
        var t: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| {
            t[i] = "skills/" ++ field.name;
        }
        break :blk t;
    };
    return table[@intFromEnum(skill_id)];
}

/// One entry in the inventory sidebar's material stack.
/// Static display info for one material kind (the parts that don't vary by
/// context). The single source of truth for the five-material icon set —
/// every material-icon site in the UI reads from `material_kinds` so the
/// sprite / color / name mapping can't drift between them. Counts are
/// context-specific (inventory totals vs mission-complete harvest vs new-
/// clone summary) and supplied per site via a `types.Materials` value.
const MaterialKind = struct {
    sprite_id: []const u8,
    color_index: u32,
    /// Display name for the tooltip (e.g. "Wood").
    name: []const u8,
};

/// The five material kinds in display order (top-to-bottom for vertical
/// stacks, left-to-right for horizontal rows).
pub const material_kinds = [_]MaterialKind{
    .{ .sprite_id = "ui/material_wood", .color_index = 5, .name = "Wood" },
    .{ .sprite_id = "ui/material_metal", .color_index = 2, .name = "Metal" },
    .{ .sprite_id = "ui/material_leather", .color_index = 5, .name = "Leather" },
    .{ .sprite_id = "ui/material_cloth", .color_index = 2, .name = "Cloth" },
    .{ .sprite_id = "ui/material_knowledge", .color_index = 0, .name = "Knowledge" },
};

/// Read the count for `kind_index` out of `materials`. Kept as a switch so
/// adding a material kind is a compile error until every index is handled.
pub fn materialCount(materials: types.Materials, kind_index: usize) u32 {
    return switch (kind_index) {
        0 => materials.wood,
        1 => materials.metal,
        2 => materials.leather,
        3 => materials.cloth,
        4 => materials.knowledge,
        else => unreachable,
    };
}

/// Layout direction for `emitMaterialIcons`: `.vertical` stacks icons flush
/// (no gap, step = icon_size downward); `.horizontal` spaces them with
/// `ui_gap` (step = icon_size + ui_gap rightward). Matches the two layouts
/// the material-icon sites use (sidebar / harvest column = vertical;
/// new-clone summary row = horizontal).
const MaterialIconDirection = enum { vertical, horizontal };

/// Emit the five material icons (each a blocking `Image` with a
/// `{count} {name}` tooltip) plus a non-blocking outlined count label in
/// each icon's bottom-right corner. Walks `material_kinds` in display order
/// starting at `origin` (top-left of the first icon), stepping by
/// `direction`. `materials` supplies the per-kind counts. The shared body
/// for the inventory sidebar, the mission-complete harvest column, and the
/// new-clone summary row — so the icon set + tooltip format can't drift.
pub fn emitMaterialIcons(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    origin: ScreenPosition,
    icon_size: i32,
    direction: MaterialIconDirection,
    materials: types.Materials,
    active_theme: types.ActiveColorTheme,
) !void {
    const p = active_theme.player_gradient.colors;
    var pos = origin;
    for (material_kinds, 0..) |kind, index| {
        const count = materialCount(materials, index);
        const icon_color = p[@min(kind.color_index, types.gradient_color_count - 1)];
        const tooltip_text = try std.fmt.allocPrint(allocator, "{d} {s}", .{ count, kind.name });
        try elements.append(allocator, .{ .image = .{
            .sprite_id = kind.sprite_id,
            .screen_position = pos,
            .width = icon_size,
            .height = icon_size,
            .color = icon_color,
            .tooltip = .{ .header = try spanRow(allocator, text(tooltip_text)) },
        } });
        // Count label: bottom-right corner of the icon, outlined for
        // readability over the icon art. Passes hover through to the icon
        // so the icon's tooltip is the single target.
        const count_text = try std.fmt.allocPrint(allocator, "{d}", .{count});
        const label_width = font_metrics.measureSpanWidth(text(count_text), material_count_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = count_text,
            .screen_position = .{
                .x = pos.x + icon_size - label_width - material_count_inset,
                .y = pos.y + icon_size - material_count_font_size - material_count_inset,
            },
            .font_size = material_count_font_size,
            .outlined = true,
            .blocks_input = false,
        } });
        switch (direction) {
            .vertical => pos.y += icon_size,
            .horizontal => pos.x += icon_size + ui_gap,
        }
    }
}

/// The comparison color for one item stat number against its equipped
/// baseline: green while better, red while worse, lightest while equal.
/// Weapons compare against BOTH hands and need the two-baseline rule —
/// see `emitItemStatLabels`.
fn statComparisonColor(
    value: u32,
    baseline: u32,
    active_theme: types.ActiveColorTheme,
) Color {
    if (value > baseline) return positive_color;
    if (value < baseline) return negative_color;
    return active_theme.lightest;
}

/// Which icon corner a stat number sits in: the first stat (single-stat
/// items' only stat; armor's health bonus) sits BOTTOM-LEFT and armor's
/// item-specific stat BOTTOM-RIGHT — both bottom-aligned (the material-
/// count row), never top-left: the icons' top-left carries defining
/// sprite art (weapon silhouettes especially) that numbers must not
/// cover.
const StatNumberCorner = enum { bottom_left, bottom_right };

/// One corner stat number on an inventory item icon: the stat VALUE (not
/// the signed difference — the tooltip carries that), colored by the
/// equipped comparison, black-outlined. The material-count label recipe:
/// same font size + inset, non-blocking so hover/click reach the slot
/// beneath (the slot keeps its tooltip).
/// The bottom-aligned corner position for a stat number label:
/// bottom-left fixed at the inset, bottom-right right-aligned on the
/// measured `label_width`.
fn statNumberPosition(
    cell_position: ScreenPosition,
    cell_size: i32,
    corner: StatNumberCorner,
    label_width: i32,
) ScreenPosition {
    return switch (corner) {
        .bottom_left => .{
            .x = cell_position.x + material_count_inset,
            .y = cell_position.y + cell_size - material_count_font_size - material_count_inset,
        },
        .bottom_right => .{
            .x = cell_position.x + cell_size - label_width - material_count_inset,
            .y = cell_position.y + cell_size - material_count_font_size - material_count_inset,
        },
    };
}

fn emitItemStatNumber(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell_position: ScreenPosition,
    cell_size: i32,
    value: u32,
    color: Color,
    corner: StatNumberCorner,
) !void {
    const value_text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    const label_width = font_metrics.measureSpanWidth(text(value_text), material_count_font_size);
    try elements.append(allocator, .{ .text_label = .{
        .text = value_text,
        .screen_position = statNumberPosition(cell_position, cell_size, corner, label_width),
        .color = color,
        .font_size = material_count_font_size,
        .outlined = true,
        .blocks_input = false,
    } });
}

/// Emit an inventory item's stat numbers directly on its icon — the
/// at-a-glance version of the item tooltip's stat rows (same stats, same
/// equipped baseline; the tooltip carries the signed differences). One
/// number per stat, colored by the equipped comparison: green while
/// better, red while worse, lightest while equal; a weapon compares
/// INCLUSIVELY against both hands — green while it at least matches each
/// hand AND strictly beats at least one (≥ each + > one: a weapon equal
/// to your best hand is still green — it upgrades the other), red while
/// it at most matches each hand AND strictly loses to at least one (≤
/// each + < one: no hand is an upgrade), lightest when it changes
/// nothing (equal to BOTH hands — a pure sidegrade) or strictly beats
/// one hand and strictly loses to the other: no clear upgrade either
/// way. An
/// empty equipped slot compares against 0
/// (an item beats nothing — green), matching the tooltip. Single-stat
/// items (weapons: damage, amulets: spell damage) show the number
/// bottom-left; armor shows the health bonus bottom-left and the
/// item-specific stat (defense / damage / pickup radius / speed)
/// bottom-right — both bottom-aligned, out of the icons' defining
/// top-left art. An UNLEARNED skill tome wears a green outlined "!" in
/// the bottom-left corner (the at-a-glance version of the tooltip's
/// "Activate to learn" line; a learned tome shows nothing — its skill
/// is known, its only remaining value is salvaging) — baseline-
/// independent, so it emits even while the stat comparison is suppressed.
/// `equipped == null` (comparison suppressed) emits no stat numbers. The
/// caller suppresses on the drag source (rides the item
/// icon — the item reads as in flight).
pub fn emitItemStatLabels(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    cell_position: ScreenPosition,
    cell_size: i32,
    item: types.Item,
    learned_skills: []const SkillId,
    equipped: ?EquippedGear,
    active_theme: types.ActiveColorTheme,
) !void {
    // The unlearned-tome marker comes first: it depends only on the
    // learned-skill set, not on the equipped baseline.
    switch (item) {
        .skill_tome => |tome| {
            if (!isSkillLearnedIn(learned_skills, tome.skill)) {
                const label_width = font_metrics.measureSpanWidth(text("!"), material_count_font_size);
                try elements.append(allocator, .{ .text_label = .{
                    .text = "!",
                    .screen_position = statNumberPosition(
                        cell_position,
                        cell_size,
                        .bottom_left,
                        label_width,
                    ),
                    .color = positive_color,
                    .font_size = material_count_font_size,
                    .outlined = true,
                    .blocks_input = false,
                } });
            }
            return;
        },
        else => {},
    }
    const e = equipped orelse return;
    switch (item) {
        .weapon => |weapon| {
            const main_hand: u32 = if (e.main_hand_weapon) |w| w.weapon_damage else 0;
            const off_hand: u32 = if (e.off_hand_weapon) |w| w.weapon_damage else 0;
            // Inclusive both-hands comparison (see the doc above): ≥ each
            // hand + strictly beats at least one → green (a weapon matching
            // your best hand upgrades the other); ≤ each hand + strictly
            // loses to at least one → red; equal to BOTH hands (changes
            // nothing) or strictly between them → lightest (no clear
            // upgrade).
            const color: Color =
                if (weapon.weapon_damage >= main_hand and weapon.weapon_damage >= off_hand and
                    (weapon.weapon_damage > main_hand or weapon.weapon_damage > off_hand))
                    positive_color
                else if (weapon.weapon_damage <= main_hand and weapon.weapon_damage <= off_hand and
                    (weapon.weapon_damage < main_hand or weapon.weapon_damage < off_hand))
                    negative_color
                else
                    active_theme.lightest;
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                weapon.weapon_damage,
                color,
                .bottom_left,
            );
        },
        .amulet => |amulet| {
            const baseline: u32 = if (e.amulet) |a| a.spell_damage else 0;
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                amulet.spell_damage,
                statComparisonColor(amulet.spell_damage, baseline, active_theme),
                .bottom_left,
            );
        },
        .coat => |coat| {
            const health_baseline: u32 = if (e.coat) |c| c.health_bonus else 0;
            const defense_baseline: u32 = if (e.coat) |c| c.defense_bonus else 0;
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                coat.health_bonus,
                statComparisonColor(coat.health_bonus, health_baseline, active_theme),
                .bottom_left,
            );
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                coat.defense_bonus,
                statComparisonColor(coat.defense_bonus, defense_baseline, active_theme),
                .bottom_right,
            );
        },
        .gloves => |gloves| {
            const health_baseline: u32 = if (e.gloves) |g| g.health_bonus else 0;
            const damage_baseline: u32 = if (e.gloves) |g| g.damage_bonus else 0;
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                gloves.health_bonus,
                statComparisonColor(gloves.health_bonus, health_baseline, active_theme),
                .bottom_left,
            );
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                gloves.damage_bonus,
                statComparisonColor(gloves.damage_bonus, damage_baseline, active_theme),
                .bottom_right,
            );
        },
        .pants => |pants| {
            const health_baseline: u32 = if (e.pants) |p| p.health_bonus else 0;
            const pickup_baseline: u32 = if (e.pants) |p| p.pickup_radius_bonus else 0;
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                pants.health_bonus,
                statComparisonColor(pants.health_bonus, health_baseline, active_theme),
                .bottom_left,
            );
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                pants.pickup_radius_bonus,
                statComparisonColor(pants.pickup_radius_bonus, pickup_baseline, active_theme),
                .bottom_right,
            );
        },
        .boots => |boots| {
            const health_baseline: u32 = if (e.boots) |b| b.health_bonus else 0;
            const speed_baseline: u32 = if (e.boots) |b| b.speed_bonus else 0;
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                boots.health_bonus,
                statComparisonColor(boots.health_bonus, health_baseline, active_theme),
                .bottom_left,
            );
            try emitItemStatNumber(
                elements,
                allocator,
                font_metrics,
                cell_position,
                cell_size,
                boots.speed_bonus,
                statComparisonColor(boots.speed_bonus, speed_baseline, active_theme),
                .bottom_right,
            );
        },
        .skill_tome => {}, // handled by the marker path above (returns there)
    }
}

/// Sprite id for an item's inventory/gear icon. Weapons resolve per
/// `WeaponType` (Unity's `WandItem` maps to our `staff`); gear types have
/// one icon each; `skill_tome` uses a single generic tome icon (the taught
/// skill is separate info; a per-skill tome icon is not wired — see TODO →
/// UI Framework). All item icons live under `assets/items/` at 128×128
/// (ported from the Unity `Resources/Items/` sprites at native size). See
/// DESIGN → UI Framework.
pub fn itemIconSpriteId(item: types.Item) []const u8 {
    return switch (item) {
        .weapon => |weapon| switch (weapon.weapon_type) {
            .sword => "items/sword",
            .shield => "items/shield",
            .spear => "items/spear",
            .dagger => "items/dagger",
            .axe => "items/axe",
            .staff => "items/staff",
        },
        .amulet => "items/amulet",
        .coat => "items/coat",
        .gloves => "items/gloves",
        .pants => "items/pants",
        .boots => "items/boots",
        .skill_tome => "items/skill_tome",
    };
}


/// The sprite id for an active-effect icon in the UI (bottom-bar effects
/// grid + entity-inspect panel). Effects created by a skill share the skill's
/// tag name (EffectId and SkillId overlap: `reflect`, `stone_form`,
/// `that_which_lingers`), so the skill's icon (`skills/<tag>`) is used —
/// the effect's own `effect_sprite` is a WORLD overlay (under
/// `assets/effects/`), not a UI icon. Non-skill effects without a
/// matching SkillId fall back to the effect-sprite path
/// (`effects/<effect_sprite>`) or the effect name (magenta placeholder).
pub fn effectIconSpriteId(effect_id: types.EffectId, definition: Effect) []const u8 {
    const tag = @tagName(effect_id);
    if (std.meta.stringToEnum(SkillId, tag)) |skill_id| {
        return skillIconSpriteId(skill_id);
    }
    if (definition.effect_sprite) |sprite| return sprite;
    return definition.name;
}
