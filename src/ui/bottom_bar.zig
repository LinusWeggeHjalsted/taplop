//! The in-game bottom bar: inventory/gear/skills buttons, the health
//! globe, weapon skill slots 1-3, swap, utility skills 4-8, skip — plus
//! the momentum/turn-step/effect indicators.

const std = @import("std");
const types = @import("../types.zig");
const ui_element = @import("element.zig");
const emit = @import("emit.zig");
const tooltip = @import("tooltip.zig");
const state = @import("../state.zig");
const lookups = @import("../generated_lookups.zig");

const Action = types.Action;
const Rectangle = types.Rectangle;
const SkillId = types.SkillId;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const weapon_type_count = @typeInfo(types.WeaponType).@"enum".fields.len;
const GameState = state.GameState;
const TooltipRow = ui_element.TooltipRow;
const text = ui_element.text;
const FontMetrics = ui_element.FontMetrics;
const UiElementList = ui_element.UiElementList;
const SlotRef = ui_element.SlotRef;
const Row = ui_element.Row;
const slot_size = ui_element.slot_size;
const ui_gap = ui_element.ui_gap;
const small_icon_size = ui_element.small_icon_size;
const health_globe_ball_size = ui_element.health_globe_ball_size;
const health_globe_border_width = ui_element.health_globe_border_width;
const health_globe_border_height = ui_element.health_globe_border_height;
const swap_button_size = ui_element.swap_button_size;
const bottom_bar_height = ui_element.bottom_bar_height;
const spanRow = tooltip.spanRow;
const emitCenteredNumber = emit.emitCenteredNumber;
const emitCornerNumber = emit.emitCornerNumber;
const emitIconButton = emit.emitIconButton;
const emitSkillButton = emit.emitSkillButton;
const effectIconSpriteId = emit.effectIconSpriteId;
const playerEntity = @import("panels.zig").playerEntity;
const button_background_sprite_id = emit.button_background_sprite_id;
const overlay_font_size = emit.overlay_font_size;


/// The bottom bar: one horizontally-centered row anchored to the bottom
/// of `screen`, laid out left-to-right as
///   inventory, gear, skills, health, weapon-skills, swap, utility-skills, skip
/// with `ui_gap` between top-level items. The two skill sub-bars pack
/// their buttons flush (no gap). Skip appears only in levels. The bar has
/// no background of its own — it is purely a layout region.
pub fn buildBottomBar(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    screen: Rectangle,
    game_state: *const GameState,
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    active_theme: types.ActiveColorTheme,
    player_color_index: u32,
    /// The slot currently being dragged from, if any. Suppresses the source
    /// skill's render so it reads as "in flight". Passed to `emitSkillButton`.
    drag_source: ?SlotRef,
) !void {
    const player = playerEntity(game_state) orelse return;
    const in_level = game_state.screen == .level;
    // The skill awaiting target confirmation (player_prepare_skill set it;
    // confirm/cancel/clear_prepared_skill clears it). Null in a hub (no
    // level) or when no skill is prepared. Used to highlight its slot.
    const prepared_skill: ?SkillId = if (in_level) blk: {
        if (game_state.level) |level| break :blk level.prepared_skill;
        break :blk null;
    } else null;

    // Player-gradient colors for the bottom bar elements.
    const p = active_theme.player_gradient.colors;
    const c_btn = p[@min(@as(u32, 4), types.gradient_color_count - 1)]; // inventory/gear/skills: 4
    const c_globe_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)]; // health bg: 5
    const c_globe_fill = p[@min(@as(u32, 1), types.gradient_color_count - 1)]; // health fill: 1
    const c_border = p[@min(@as(u32, 3), types.gradient_color_count - 1)]; // border/skill bg/skip bg/turn/swap/momentum: 3
    const c_icon = p[@min(@as(u32, 1), types.gradient_color_count - 1)]; // skill/skip icon: 1
    const c_skip_bg = p[@min(@as(u32, 5), types.gradient_color_count - 1)]; // skip bg: 5
    _ = player_color_index; // UI uses fixed indices, not the player's chosen index

    const weapon_skills_width = 3 * slot_size;
    const utility_skills_width = 5 * slot_size;

    // Total content width, to size and center the row.
    var top_level_count: i32 = 7; // inventory,gear,skills,health,wpn,swap,util
    // The health globe cell is wider than slot_size to fit its border at
    // native size (297 vs 256) — the border is authored wider than a slot, so
    // the cell matches it rather than letting the border overhang into the
    // gaps (which crowded the neighbors — see health_globe_border_width).
    var content_width = slot_size * 3 // inventory, gear, skills
        + health_globe_border_width // health (wider than a slot)
        + weapon_skills_width + swap_button_size + utility_skills_width;
    if (in_level) {
        top_level_count += 1;
        content_width += slot_size;
    }
    content_width += ui_gap * (top_level_count - 1);

    const bar = screen.placeBottomCenter(content_width, bottom_bar_height, 0);
    var row = Row.init(bar.position(), bottom_bar_height, ui_gap);

    // Panel toggle buttons.
    const toggles = [_]struct { sprite: []const u8, action: Action, label: []const u8 }{
        .{ .sprite = "ui/icon_inventory", .action = .toggle_inventory, .label = "Inventory" },
        .{ .sprite = "ui/icon_gear", .action = .toggle_gear, .label = "Gear" },
        .{ .sprite = "ui/icon_skills", .action = .toggle_skills, .label = "Skills" },
    };
    for (toggles) |toggle| {
        try elements.append(allocator, .{ .button = .{
            .sprite_id = toggle.sprite,
            .screen_position = row.next(slot_size).position(),
            .action = toggle.action,
            .color = c_btn,
            .tooltip = .{ .header = try spanRow(allocator, text(toggle.label)) },
        } });
    }

    // Health globe (vertical fill).
    const health_cell = row.next(health_globe_border_width);
    // One flat white ball serves as both background and fill; tint reads
    // them as depleted vs current health. Rendered at the ball's native
    // (downscaled) size, centered in the cell so it sits inside the border.
    const ball = health_cell.placeCenter(health_globe_ball_size, health_globe_ball_size);
    try elements.append(allocator, .{ .fill_sprite = .{
        .background_sprite_id = "ui/health_globe",
        .fill_sprite_id = "ui/health_globe",
        .screen_position = ball.position(),
        .width = health_globe_ball_size,
        .height = health_globe_ball_size,
        .fill_fraction = if (player.getEffectiveMaxHealth() == 0)
            0
        else
            @as(f32, @floatFromInt(player.current_health)) /
                @as(f32, @floatFromInt(player.getEffectiveMaxHealth())),
        .fill_direction = .up,
        .background_color = c_globe_bg,
        .fill_color = c_globe_fill,
        .tooltip = .{ .header = try spanRow(allocator, text(
            try std.fmt.allocPrint(allocator, "{d} / {d}", .{ player.current_health, player.getEffectiveMaxHealth() }),
        )) },
    } });
    // Stylized border drawn over the globe at its native size, centered on the
    // cell (co-registered with the ball). Slightly wider than the cell, so it
    // overhangs horizontally. Hover passes through to the globe.
    const border = health_cell.placeCenter(health_globe_border_width, health_globe_border_height);
    try elements.append(allocator, .{ .image = .{
        .sprite_id = "ui/health_globe_border",
        .screen_position = border.position(),
        .width = health_globe_border_width,
        .height = health_globe_border_height,
        .color = c_border,
        .blocks_input = false,
    } });

    // Current-health number centered on the ball, outlined for readability
    // over the fill. Passes hover through to the globe (the tooltip shows
    // `current / max`). Drawn AFTER the border so it sits on top of both.
    {
        const health_text = try std.fmt.allocPrint(allocator, "{d}", .{player.current_health});
        const label_width = font_metrics.measureSpanWidth(text(health_text), overlay_font_size);
        const label_box = ball.placeCenter(label_width, overlay_font_size);
        try elements.append(allocator, .{ .text_label = .{
            .text = health_text,
            .screen_position = label_box.position(),
            .font_size = overlay_font_size,
            .outlined = true,
            .blocks_input = false,
        } });
    }

    // Weapon skills sub-bar (slots 1-3, packed flush).
    const weapon_sub_bar = row.next(weapon_skills_width);
    {
        var inner = Row.init(weapon_sub_bar.position(), bottom_bar_height, 0);
        var slot: u8 = 1;
        while (slot <= 3) : (slot += 1) {
            // Weapon-skill slots are derived from the equipped weapon — not
            // reorderable, so no drag ref.
            try emitSkillButton(elements, allocator, font_metrics, inner.next(slot_size), slot, player, weapon_type_definitions, c_border, c_icon, prepared_skill, active_theme.darkest, null, drag_source);
        }
    }

    // Weapon swap button (128, centered vertically in its cell).
    {
        const cell = row.next(swap_button_size);
        try elements.append(allocator, .{ .button = .{
            .sprite_id = "ui/icon_swap",
            .screen_position = cell.placeCenter(swap_button_size, swap_button_size).position(),
            .width = swap_button_size,
            .height = swap_button_size,
            .action = .swap_weapons,
            .color = c_border,
            .tooltip = .{ .header = try spanRow(allocator, text("Swap weapons")) },
        } });
    }

    // Utility skills sub-bar (slots 4-8, packed flush).
    const utility_sub_bar = row.next(utility_skills_width);
    {
        var inner = Row.init(utility_sub_bar.position(), bottom_bar_height, 0);
        var slot: u8 = 4;
        while (slot <= 8) : (slot += 1) {
            // Utility-skill slots are reorderable by drag: ref = skill_bar
            // index 0-4 (slot 4 → index 0, ..., slot 8 → index 4).
            try emitSkillButton(elements, allocator, font_metrics, inner.next(slot_size), slot, player, weapon_type_definitions, c_border, c_icon, prepared_skill, active_theme.darkest, .{ .skill_bar = @as(u32, slot - 4) }, drag_source);
        }
    }

    // Skip button — levels only.
    var skip_cell: ?Rectangle = null;
    if (in_level) {
        const cell = row.next(slot_size);
        skip_cell = cell;
        try emitIconButton(
            elements,
            allocator,
            cell,
            button_background_sprite_id,
            "ui/icon_skip",
            .skip,
            .{ .header = try spanRow(allocator, text("Skip turn step")) },
            c_skip_bg,
            c_icon,
            false,
            null,
        );
    }

    // --- Indicators above the bar (16px gap, 128×128) ---

    // Momentum: centered above the health globe (levels only).
    if (in_level) {
        const momentum_cell = health_cell
            .placeTopCenter(small_icon_size, small_icon_size, 0)
            .translate(0, -(ui_gap + small_icon_size));
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/momentum",
            .screen_position = momentum_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .tooltip = .{
                .header = try spanRow(allocator, text(
                    try std.fmt.allocPrint(allocator, "{d} momentum", .{player.momentum}),
                )),
                .body = try allocator.dupe(TooltipRow, &.{
                    try spanRow(allocator, text(
                        try std.fmt.allocPrint(allocator, "+{d} damage", .{player.getConvertedMomentum()}),
                    )),
                }),
            },
        } });
        try emitCenteredNumber(elements, allocator, font_metrics, momentum_cell, player.momentum, overlay_font_size);
    }

    // Active effects: flush 128 grid spanning the skill bars, filling
    // right-to-left (oldest rightmost) then wrapping upward.
    if (player.active_effects.len > 0) {
        const span_right = utility_sub_bar.right();
        const span_width = utility_sub_bar.right() - weapon_sub_bar.x;
        const columns = @max(1, @divFloor(span_width, small_icon_size));
        const bottom_row_top = bar.y - ui_gap - small_icon_size;
        for (player.active_effects, 0..) |effect, index| {
            const ordinal: i32 = @intCast(index);
            const column = @mod(ordinal, columns);
            const grid_row = @divFloor(ordinal, columns);
            const cell: Rectangle = .{
                .x = span_right - (column + 1) * small_icon_size,
                .y = bottom_row_top - grid_row * small_icon_size,
                .width = small_icon_size,
                .height = small_icon_size,
            };
            const definition = lookups.getEffectDefinition(effect.effect_id);
            try elements.append(allocator, .{ .image = .{
                .sprite_id = effectIconSpriteId(effect.effect_id, definition),
                .screen_position = cell.position(),
                .width = small_icon_size,
                .height = small_icon_size,
                .color = c_icon,
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
    }

    // Turn-step icons: move + attack above the skip button (levels only),
    // combined width equal to the skip button. The current phase is
    // highlighted; neither is highlighted during enemy turns.
    if (skip_cell) |skip| {
        const turn_phase = if (game_state.level) |level| level.turn_phase else null;
        const strip: Rectangle = .{
            .x = skip.x,
            .y = bar.y - ui_gap - small_icon_size,
            .width = skip.width,
            .height = small_icon_size,
        };
        var inner = Row.init(strip.position(), small_icon_size, 0);
        const move_cell = inner.next(small_icon_size);
        const attack_cell = inner.next(small_icon_size);
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/turn_move",
            .screen_position = move_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .highlighted = turn_phase == .player_move,
            .tooltip = .{ .header = try spanRow(allocator, text("Move step")) },
        } });
        try elements.append(allocator, .{ .image = .{
            .sprite_id = "ui/turn_attack",
            .screen_position = attack_cell.position(),
            .width = small_icon_size,
            .height = small_icon_size,
            .color = c_border,
            .highlighted = turn_phase == .player_attack,
            .tooltip = .{ .header = try spanRow(allocator, text("Attack step")) },
        } });
    }
}
