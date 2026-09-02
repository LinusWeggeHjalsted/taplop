//! Tooltip placement + content builders: `placeTooltip` (side-based pure
//! geometry), `buildTooltip` (wrap + measure into a panel), and the
//! authored content builders — `buildSkillTooltip`, `buildItemTooltip`
//! (with equipped-gear stat comparisons + the learned-skill prompt). The
//! span content model + `wrapRow` live in element.zig. See DESIGN → UI
//! Framework.

const std = @import("std");
const types = @import("../types.zig");
const element = @import("element.zig");
const lookups = @import("../generated_lookups.zig");
const Skill = @import("../skills/skill.zig").Skill;

const Action = types.Action;
const ScreenPosition = types.ScreenPosition;
const Rectangle = types.Rectangle;
const Color = types.Color;
const Entity = types.Entity;
const Span = element.Span;
const TooltipRow = element.TooltipRow;
const Tooltip = element.Tooltip;
const text = element.text;
const colored = element.colored;
const bold = element.bold;
const italic = element.italic;
const lineHeight = element.lineHeight;
const FontMetrics = element.FontMetrics;
const default_tint = element.default_tint;
const wrapRow = element.wrapRow;
const WrappedRow = element.WrappedRow;
const UiElementList = element.UiElementList;

/// One side of the source element a tooltip can sit flush against.
pub const Side = enum { right, below, left, above };

/// Place the tooltip flush against one side of the source element so they
/// share an edge (not just a corner). Tries sides in a fixed preference
/// order — above, below, right, left — and uses the first that fits on
/// screen without clamping, so tooltips prefer going above an element
/// (the natural direction, especially for the bottom bar) and only fall
/// sideways when there's no vertical room. If no side fits fully, falls back
/// to the top preference (above) and clamps. Aligns the tooltip to the near
/// corner along the chosen side — e.g. above with the source in the left
/// half left-aligns the tooltip, so the shared edge runs from the source's
/// top-left corner rightward. Clamping shifts the tooltip along the
/// cross-axis, shrinking the shared edge but keeping the sides flush
/// (degenerates to a point only if the tooltip is larger than the available
/// cross-axis space).
pub fn placeTooltip(
    source_position: ScreenPosition,
    source_width: i32,
    source_height: i32,
    tooltip_width: i32,
    tooltip_height: i32,
) struct { x: i32, y: i32 } {
    const source_right = source_position.x + source_width;
    const source_bottom = source_position.y + source_height;
    const screen_w = types.reference_width;
    const screen_h = types.reference_height;
    const source_center_x = source_position.x + @divTrunc(source_width, 2);
    const source_center_y = source_position.y + @divTrunc(source_height, 2);
    const left_half = source_center_x < @divTrunc(screen_w, 2);
    const top_half = source_center_y < @divTrunc(screen_h, 2);

    // Candidate position for each side, in preference order (above, below,
    // right, left). Each is flush on its side and aligned to the near corner
    // along that side.
    const positions = [_]struct { x: i32, y: i32 }{
        // above: flush over the source, horizontally near-corner-aligned.
        .{ .x = if (left_half) source_position.x else source_right - tooltip_width, .y = source_position.y - tooltip_height },
        // below: flush under the source, horizontally near-corner-aligned.
        .{ .x = if (left_half) source_position.x else source_right - tooltip_width, .y = source_bottom },
        // right: flush to the right, vertically near-corner-aligned.
        .{ .x = source_right, .y = if (top_half) source_position.y else source_bottom - tooltip_height },
        // left: flush to the left, vertically near-corner-aligned.
        .{ .x = source_position.x - tooltip_width, .y = if (top_half) source_position.y else source_bottom - tooltip_height },
    };

    // First side that fits on screen without clamping wins.
    for (positions) |pos| {
        if (pos.x >= 0 and pos.x + tooltip_width <= screen_w and pos.y >= 0 and pos.y + tooltip_height <= screen_h)
            return .{ .x = pos.x, .y = pos.y };
    }

    // None fit fully — fall back to the top preference (above), clamped.
    // `@max(0, …)` guards an oversized tooltip (taller/wider than the
    // reference screen): screen - tooltip goes negative, and clamp requires
    // lo <= hi. Clamping to 0 pins the top-left corner — the best placement
    // when the panel can't fit anywhere.
    const fallback = positions[0];
    return .{
        .x = std.math.clamp(fallback.x, 0, @max(0, screen_w - tooltip_width)),
        .y = std.math.clamp(fallback.y, 0, @max(0, screen_h - tooltip_height)),
    };
}

// ============================================================
// Tooltip layout
// ============================================================
// Measures and wraps a Tooltip's rows against the padded content area, then
// positions a background panel plus one TextLabel per span. Written entirely
// against the measurement seam (measureSpanWidth / lineHeight), so it is
// deterministic and testable regardless of the eventual font.

pub const tooltip_max_width: i32 = 1024;
pub const tooltip_padding: i32 = 24; // inner padding around content
pub const tooltip_row_gap: i32 = 8; // vertical gap between rows
pub const tooltip_header_gap: i32 = 16; // extra gap below the header
pub const tooltip_header_font_size: i32 = 64;
pub const tooltip_body_font_size: i32 = 56;
pub const tooltip_panel_sprite = "ui/panel";

/// Append a tooltip (background panel + positioned text) for `tooltip`,
/// anchored to the element at the given source bounds. No-op for empty
/// tooltips.
pub fn buildTooltip(
    elements: *UiElementList,
    allocator: std.mem.Allocator,
    font_metrics: FontMetrics,
    source_position: ScreenPosition,
    source_width: i32,
    source_height: i32,
    tooltip: Tooltip,
) !void {
    const content_width_limit = tooltip_max_width - 2 * tooltip_padding;

    // Wrap every row up front so the panel can be sized before placement.
    var wrapped: std.ArrayList(WrappedRow) = .empty;
    if (tooltip.header) |header| {
        try wrapped.append(allocator, .{
            .font_size = tooltip_header_font_size,
            .lines = try wrapRow(allocator, font_metrics, header, tooltip_header_font_size, content_width_limit),
            .is_header = true,
        });
    }
    for (tooltip.body) |body_row| {
        try wrapped.append(allocator, .{
            .font_size = tooltip_body_font_size,
            .lines = try wrapRow(allocator, font_metrics, body_row, tooltip_body_font_size, content_width_limit),
            .is_header = false,
        });
    }
    if (wrapped.items.len == 0) return;

    // Size: widest visual line (capped) for width; stacked line heights plus
    // inter-row and header gaps for height. This loop mirrors the emit loop.
    var content_width: i32 = 0;
    var content_height: i32 = 0;
    for (wrapped.items, 0..) |wrapped_row, row_index| {
        if (row_index > 0) content_height += tooltip_row_gap;
        for (wrapped_row.lines) |line| {
            const line_width = @min(font_metrics.measureRowWidth(line, wrapped_row.font_size), content_width_limit);
            if (line_width > content_width) content_width = line_width;
            content_height += lineHeight(wrapped_row.font_size);
        }
        if (wrapped_row.is_header) content_height += tooltip_header_gap;
    }

    const panel_width = content_width + 2 * tooltip_padding;
    const panel_height = content_height + 2 * tooltip_padding;

    // Place flush against one side of the source (shared edge), clamped on screen.
    const placement = placeTooltip(source_position, source_width, source_height, panel_width, panel_height);
    const panel_x = placement.x;
    const panel_y = placement.y;

    try elements.append(allocator, .{ .nine_slice_panel = .{
        .sprite_id = tooltip_panel_sprite,
        .screen_position = .{ .x = panel_x, .y = panel_y },
        .width = panel_width,
        .height = panel_height,
        // The tooltip is a passive overlay; it never captures the pointer.
        .blocks_input = false,
    } });

    const content_x = panel_x + tooltip_padding;
    var y = panel_y + tooltip_padding;
    for (wrapped.items, 0..) |wrapped_row, row_index| {
        if (row_index > 0) y += tooltip_row_gap;
        for (wrapped_row.lines) |line| {
            var x = content_x;
            for (line) |span| {
                try elements.append(allocator, .{ .text_label = .{
                    .text = span.text,
                    .screen_position = .{ .x = x, .y = y },
                    .color = span.color,
                    .font_size = wrapped_row.font_size,
                    .bold = span.bold,
                    .italic = span.italic,
                    .blocks_input = false,
                } });
                x += font_metrics.measureSpanWidth(span, wrapped_row.font_size);
            }
            y += lineHeight(wrapped_row.font_size);
        }
        if (wrapped_row.is_header) y += tooltip_header_gap;
    }
}

/// A one-span row, arena-allocated so it outlives the builder.
pub fn spanRow(allocator: std.mem.Allocator, span: Span) !TooltipRow {
    return allocator.dupe(Span, &.{span});
}

/// Display name for a skill type (e.g. .weapon_skill -> "Weapon Skill").
fn skillTypeName(skill_type: types.SkillType) []const u8 {
    return switch (skill_type) {
        .weapon_skill => "Weapon Skill",
        .spell => "Spell",
        .cantrip => "Cantrip",
        .enchantment => "Enchantment",
        .curse => "Curse",
    };
}

/// Display name for a weapon type (e.g. .sword -> "Sword").
fn weaponTypeName(weapon_type: types.WeaponType) []const u8 {
    return switch (weapon_type) {
        .sword => "Sword",
        .shield => "Shield",
        .spear => "Spear",
        .dagger => "Dagger",
        .axe => "Axe",
        .staff => "Staff",
    };
}

/// Display name for an item type (e.g. .amulet -> "Amulet"). Weapons are
/// handled by `weaponTypeName` (they carry a sub-type).
fn itemTypeName(item: types.Item) []const u8 {
    return switch (item) {
        .weapon => |w| weaponTypeName(w.weapon_type),
        .amulet => "Amulet",
        .coat => "Coat",
        .gloves => "Gloves",
        .pants => "Pants",
        .boots => "Boots",
        .skill_tome => "Skill Tome",
    };
}

/// The player's equipped gear, used as the baseline for tooltip stat
/// comparisons. Mirrors the gear fields on Entity (entity 0 in a level,
/// the hub player outside one). Null fields = empty slot (baseline 0).
pub const EquippedGear = struct {
    main_hand_weapon: ?types.Weapon = null,
    off_hand_weapon: ?types.Weapon = null,
    amulet: ?types.Amulet = null,
    coat: ?types.Coat = null,
    gloves: ?types.Gloves = null,
    pants: ?types.Pants = null,
    boots: ?types.Boots = null,
};

/// Snapshot of an entity's equipped gear for tooltip comparisons.
pub fn equippedGearFromEntity(entity: Entity) EquippedGear {
    return .{
        .main_hand_weapon = entity.main_hand_weapon,
        .off_hand_weapon = entity.off_hand_weapon,
        .amulet = entity.amulet,
        .coat = entity.coat,
        .gloves = entity.gloves,
        .pants = entity.pants,
        .boots = entity.boots,
    };
}

/// Green/red for stat feedback: gear-tooltip comparisons and combat
/// damage/heal numbers (damage red, heals green — including 0 values).
pub const positive_color: Color = .{ .r = 0, .g = 255, .b = 0 };
pub const negative_color: Color = .{ .r = 255, .g = 0, .b = 0 };

/// One comparison number: "+d" green when the hovered item's stat is
/// higher, "-d" red when lower, uncolored "0" when equal.
fn comparisonSpan(
    allocator: std.mem.Allocator,
    item_value: u32,
    equipped_value: u32,
) !Span {
    const difference: i32 = @as(i32, @intCast(item_value)) - @as(i32, @intCast(equipped_value));
    if (difference > 0) {
        return colored(try std.fmt.allocPrint(allocator, "+{d}", .{difference}), positive_color);
    }
    if (difference < 0) {
        return colored(try std.fmt.allocPrint(allocator, "{d}", .{difference}), negative_color);
    }
    return text("0");
}

/// A stat row: plain "Label value" when both baselines are null
/// (comparison suppressed — gear panel, player inspect), "Label value (d)"
/// with one baseline, "Label value (d1, d2)" with both (weapons compare
/// against each equipped hand). A non-null baseline of 0 means the slot is
/// empty (compare against nothing equipped).
fn statRow(
    allocator: std.mem.Allocator,
    label: []const u8,
    value: u32,
    first_baseline: ?u32,
    second_baseline: ?u32,
) !TooltipRow {
    if (first_baseline == null and second_baseline == null) {
        const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ label, value });
        return spanRow(allocator, text(line));
    }
    var spans: std.ArrayList(Span) = .empty;
    try spans.append(allocator, text(try std.fmt.allocPrint(allocator, "{s} {d} (", .{ label, value })));
    try spans.append(allocator, try comparisonSpan(allocator, value, first_baseline orelse 0));
    if (second_baseline) |baseline| {
        try spans.append(allocator, text(", "));
        try spans.append(allocator, try comparisonSpan(allocator, value, baseline));
    }
    try spans.append(allocator, text(")"));
    return spans.toOwnedSlice(allocator);
}

/// Build an inventory item tooltip. Weapons show name + weapon type +
/// damage (compared against BOTH equipped hands); other gear shows name +
/// item type + each stat (compared against the same slot's equipped item);
/// skill tomes show the skill name + learned/learn-prompt. `learned_skills`
/// is the player's current learned-skill set (for the tome line).
/// `equipped` is the comparison baseline; null suppresses comparisons.
pub fn buildItemTooltip(
    allocator: std.mem.Allocator,
    item: types.Item,
    learned_skills: []const types.SkillId,
    equipped: ?EquippedGear,
) !Tooltip {
    switch (item) {
        .weapon => |weapon| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text(weaponTypeName(weapon.weapon_type))));
            const main_baseline: ?u32 = if (equipped) |e|
                (if (e.main_hand_weapon) |w| w.weapon_damage else 0)
            else
                null;
            const off_baseline: ?u32 = if (equipped) |e|
                (if (e.off_hand_weapon) |w| w.weapon_damage else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Damage", weapon.weapon_damage, main_baseline, off_baseline));
            return .{
                .header = try spanRow(allocator, text(weapon.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .amulet => |amulet| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Amulet")));
            const spell_baseline: ?u32 = if (equipped) |e|
                (if (e.amulet) |a| a.spell_damage else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Spell Damage", amulet.spell_damage, spell_baseline, null));
            return .{
                .header = try spanRow(allocator, text(amulet.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .coat => |coat| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Coat")));
            const health_baseline: ?u32 = if (equipped) |e|
                (if (e.coat) |c| c.health_bonus else 0)
            else
                null;
            const defense_baseline: ?u32 = if (equipped) |e|
                (if (e.coat) |c| c.defense_bonus else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Health", coat.health_bonus, health_baseline, null));
            try body.append(allocator, try statRow(allocator, "Defense", coat.defense_bonus, defense_baseline, null));
            return .{
                .header = try spanRow(allocator, text(coat.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .gloves => |gloves| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Gloves")));
            const health_baseline: ?u32 = if (equipped) |e|
                (if (e.gloves) |g| g.health_bonus else 0)
            else
                null;
            const damage_baseline: ?u32 = if (equipped) |e|
                (if (e.gloves) |g| g.damage_bonus else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Health", gloves.health_bonus, health_baseline, null));
            try body.append(allocator, try statRow(allocator, "Damage", gloves.damage_bonus, damage_baseline, null));
            return .{
                .header = try spanRow(allocator, text(gloves.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .pants => |pants| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Pants")));
            const health_baseline: ?u32 = if (equipped) |e|
                (if (e.pants) |p| p.health_bonus else 0)
            else
                null;
            const pickup_baseline: ?u32 = if (equipped) |e|
                (if (e.pants) |p| p.pickup_radius_bonus else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Health", pants.health_bonus, health_baseline, null));
            try body.append(allocator, try statRow(allocator, "Pickup Radius", pants.pickup_radius_bonus, pickup_baseline, null));
            return .{
                .header = try spanRow(allocator, text(pants.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .boots => |boots| {
            var body: std.ArrayList(TooltipRow) = .empty;
            try body.append(allocator, try spanRow(allocator, text("Boots")));
            const health_baseline: ?u32 = if (equipped) |e|
                (if (e.boots) |b| b.health_bonus else 0)
            else
                null;
            const speed_baseline: ?u32 = if (equipped) |e|
                (if (e.boots) |b| b.speed_bonus else 0)
            else
                null;
            try body.append(allocator, try statRow(allocator, "Health", boots.health_bonus, health_baseline, null));
            try body.append(allocator, try statRow(allocator, "Speed", boots.speed_bonus, speed_baseline, null));
            return .{
                .header = try spanRow(allocator, text(boots.name)),
                .body = try body.toOwnedSlice(allocator),
            };
        },
        .skill_tome => |tome| {
            const definition = lookups.getSkillDefinition(tome.skill) orelse {
                // Unknown skill id (shouldn't happen for shipped content);
                // show a minimal fallback so the slot isn't tooltip-less.
                return .{
                    .header = try spanRow(allocator, text("Skill Tome")),
                    .body = &.{},
                };
            };
            const header_text = try std.fmt.allocPrint(allocator, "{s} Tome", .{definition.name});
            const already_learned = isSkillLearnedIn(learned_skills, tome.skill);
            const body_text = if (already_learned)
                "Already learned"
            else
                try std.fmt.allocPrint(allocator, "Activate to learn {s}", .{definition.name});
            return .{
                .header = try spanRow(allocator, text(header_text)),
                .body = try allocator.dupe(TooltipRow, &.{try spanRow(allocator, text(body_text))}),
            };
        },
    }
}

/// Whether `skill_id` is in `learned_skills`. The handler-side version
/// (`handlers/player.zig` isSkillLearned) takes the same args; this local
/// copy keeps the tooltip builder self-contained (src/ui/ doesn't import
/// the handlers).
fn isSkillLearnedIn(learned_skills: []const types.SkillId, skill_id: types.SkillId) bool {
    for (learned_skills) |learned| {
        if (learned == skill_id) return true;
    }
    return false;
}

/// Build the standard skill tooltip:
///   name (header)
///   description
///   skill type
///   one "Label N" row per non-null skill variable, in interface order
/// No span styling yet — every row is a single plain span.
pub fn buildSkillTooltip(allocator: std.mem.Allocator, skill: Skill) !Tooltip {
    var body: std.ArrayList(TooltipRow) = .empty;
    try body.append(allocator, try spanRow(allocator, text(skill.description)));
    try body.append(allocator, try spanRow(allocator, text(skillTypeName(skill.skill_type))));

    const variables = [_]struct { label: []const u8, value: ?u32 }{
        .{ .label = "Range", .value = skill.range },
        .{ .label = "Radius", .value = skill.radius },
        .{ .label = "Distance", .value = skill.distance },
        .{ .label = "Duration", .value = skill.skill_duration },
        .{ .label = "Stun Duration", .value = skill.stun_duration },
        .{ .label = "Cooldown", .value = skill.cooldown },
    };
    for (variables) |variable| {
        if (variable.value) |value| {
            const line = try std.fmt.allocPrint(allocator, "{s} {d}", .{ variable.label, value });
            try body.append(allocator, try spanRow(allocator, text(line)));
        }
    }

    return .{
        .header = try spanRow(allocator, text(skill.name)),
        .body = try body.toOwnedSlice(allocator),
    };
}

test "buildSkillTooltip lays out name, description, type, then non-null vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const slice = @import("../skills/slice.zig").skill;
    const tooltip = try buildSkillTooltip(arena.allocator(), slice);
    try std.testing.expectEqualStrings("Slice", tooltip.header.?[0].text);
    // description, Weapon Skill, Range 1 (other vars are null)
    try std.testing.expectEqual(@as(usize, 3), tooltip.body.len);
    try std.testing.expectEqualStrings("Attack target, dealing 1.5x damage if they have less than half health", tooltip.body[0][0].text);
    try std.testing.expectEqualStrings("Weapon Skill", tooltip.body[1][0].text);
    try std.testing.expectEqualStrings("Range 1", tooltip.body[2][0].text);
}

test "buildItemTooltip: weapon shows name, type, damage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const weapon = types.Item{ .weapon = .{ .name = "Iron Sword", .weapon_type = .sword, .weapon_damage = 5 } };
    const tooltip = try buildItemTooltip(arena.allocator(), weapon, &.{}, null);
    try std.testing.expectEqualStrings("Iron Sword", tooltip.header.?[0].text);
    try std.testing.expectEqual(@as(usize, 2), tooltip.body.len);
    try std.testing.expectEqualStrings("Sword", tooltip.body[0][0].text);
    try std.testing.expectEqualStrings("Damage 5", tooltip.body[1][0].text);
}

test "buildItemTooltip: coat shows name, type, health, defense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const coat = types.Item{ .coat = .{ .name = "Leather Coat", .health_bonus = 3, .defense_bonus = 2 } };
    const tooltip = try buildItemTooltip(arena.allocator(), coat, &.{}, null);
    try std.testing.expectEqualStrings("Leather Coat", tooltip.header.?[0].text);
    try std.testing.expectEqual(@as(usize, 3), tooltip.body.len);
    try std.testing.expectEqualStrings("Coat", tooltip.body[0][0].text);
    try std.testing.expectEqualStrings("Health 3", tooltip.body[1][0].text);
    try std.testing.expectEqualStrings("Defense 2", tooltip.body[2][0].text);
}

test "buildItemTooltip: skill tome not learned shows learn prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tome = types.Item{ .skill_tome = .{ .skill = .slice, .value = 5 } };
    const learned = [_]types.SkillId{};
    const tooltip = try buildItemTooltip(arena.allocator(), tome, &learned, null);
    try std.testing.expectEqualStrings("Slice Tome", tooltip.header.?[0].text);
    try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
    try std.testing.expectEqualStrings("Activate to learn Slice", tooltip.body[0][0].text);
}

test "buildItemTooltip: skill tome already learned shows learned line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tome = types.Item{ .skill_tome = .{ .skill = .slice, .value = 5 } };
    const learned = [_]types.SkillId{.slice};
    const tooltip = try buildItemTooltip(arena.allocator(), tome, &learned, null);
    try std.testing.expectEqualStrings("Slice Tome", tooltip.header.?[0].text);
    try std.testing.expectEqual(@as(usize, 1), tooltip.body.len);
    try std.testing.expectEqualStrings("Already learned", tooltip.body[0][0].text);
}

test "buildItemTooltip: weapon compares damage against both equipped hands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const weapon = types.Item{ .weapon = .{ .name = "Iron Sword", .weapon_type = .sword, .weapon_damage = 5 } };
    const equipped = EquippedGear{
        .main_hand_weapon = .{ .name = "Old Sword", .weapon_type = .sword, .weapon_damage = 4 },
        .off_hand_weapon = .{ .name = "Old Dagger", .weapon_type = .dagger, .weapon_damage = 5 },
    };
    const tooltip = try buildItemTooltip(arena.allocator(), weapon, &.{}, equipped);
    // Row spans: "Damage 5 (" | "+1" green | ", " | "0" uncolored | ")"
    const row = tooltip.body[1];
    try std.testing.expectEqual(@as(usize, 5), row.len);
    try std.testing.expectEqualStrings("Damage 5 (", row[0].text);
    try std.testing.expectEqualStrings("+1", row[1].text);
    try std.testing.expectEqual(positive_color, row[1].color);
    try std.testing.expectEqualStrings(", ", row[2].text);
    try std.testing.expectEqualStrings("0", row[3].text);
    try std.testing.expectEqual(default_tint, row[3].color);
    try std.testing.expectEqualStrings(")", row[4].text);
}

test "buildItemTooltip: weapon negative comparison and empty off hand baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const weapon = types.Item{ .weapon = .{ .name = "Iron Sword", .weapon_type = .sword, .weapon_damage = 5 } };
    // Main hand does 7 (worse: -2), off hand empty (better than 0: +5).
    const equipped = EquippedGear{
        .main_hand_weapon = .{ .name = "Big Axe", .weapon_type = .axe, .weapon_damage = 7 },
    };
    const tooltip = try buildItemTooltip(arena.allocator(), weapon, &.{}, equipped);
    const row = tooltip.body[1];
    try std.testing.expectEqualStrings("-2", row[1].text);
    try std.testing.expectEqual(negative_color, row[1].color);
    try std.testing.expectEqualStrings("+5", row[3].text);
    try std.testing.expectEqual(positive_color, row[3].color);
}

test "buildItemTooltip: coat compares each stat against the equipped coat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const coat = types.Item{ .coat = .{ .name = "Leather Coat", .health_bonus = 3, .defense_bonus = 2 } };
    // Equipped coat: health 4 (worse: -1), defense 2 (equal: 0). Empty
    // slots elsewhere must not matter — only the same slot's item is read.
    const equipped = EquippedGear{
        .coat = .{ .name = "Old Coat", .health_bonus = 4, .defense_bonus = 2 },
    };
    const tooltip = try buildItemTooltip(arena.allocator(), coat, &.{}, equipped);
    const health_row = tooltip.body[1];
    try std.testing.expectEqual(@as(usize, 3), health_row.len);
    try std.testing.expectEqualStrings("Health 3 (", health_row[0].text);
    try std.testing.expectEqualStrings("-1", health_row[1].text);
    try std.testing.expectEqual(negative_color, health_row[1].color);
    try std.testing.expectEqualStrings(")", health_row[2].text);
    const defense_row = tooltip.body[2];
    try std.testing.expectEqualStrings("0", defense_row[1].text);
    try std.testing.expectEqual(default_tint, defense_row[1].color);
}

test "buildItemTooltip: empty equipped slot compares against zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const boots = types.Item{ .boots = .{ .name = "Boots", .health_bonus = 2, .speed_bonus = 1 } };
    const tooltip = try buildItemTooltip(arena.allocator(), boots, &.{}, EquippedGear{});
    const speed_row = tooltip.body[2];
    try std.testing.expectEqualStrings("+1", speed_row[1].text);
    try std.testing.expectEqual(positive_color, speed_row[1].color);
}


test "placeTooltip: source in bottom bar prefers above" {
    // A bottom-bar element: source near the bottom edge, centered horizontally.
    // `above` has ~1900px clearance (fits a 600px tooltip) and is the top
    // preference, so the tooltip sits flush over the source.
    const placement = placeTooltip(.{ .x = 1600, .y = 1900 }, 256, 256, 400, 600);
    // Flush above: panel bottom edge meets source top edge (y = 1900 - 600).
    try std.testing.expectEqual(@as(i32, 1900 - 600), placement.y);
    try std.testing.expectEqual(@as(i32, 1600), placement.x); // left-aligned (left half)
}

test "placeTooltip: source in top-left quadrant goes below" {
    // Source in the top half → `above` doesn't fit (clearance = source.y = 100
    // < tooltip height 600), so the preference order falls to `below`.
    const placement = placeTooltip(.{ .x = 200, .y = 100 }, 256, 256, 400, 600);
    // Flush below: panel top edge meets source bottom edge (y = 100 + 256).
    try std.testing.expectEqual(@as(i32, 100 + 256), placement.y);
    try std.testing.expectEqual(@as(i32, 200), placement.x); // left-aligned (left half)
}

test "placeTooltip: above doesn't fit and below doesn't fit → falls sideways" {
    // A tall source spanning most of the screen leaves no vertical room on
    // either side (above clearance = source.y = 200, below = 360, both < tooltip
    // height 400), so the preference order falls past above/below to `right`.
    // The tooltip is short enough that its vertical alignment (top-align) stays
    // on screen, so `right` fits.
    const placement = placeTooltip(.{ .x = 1000, .y = 200 }, 256, 1600, 500, 400);
    // Flush right: panel left edge meets source right edge (x = 1000 + 256).
    try std.testing.expectEqual(@as(i32, 1000 + 256), placement.x);
    // top-aligned (source center y = 200+800 = 1000 < screen center 1080).
    try std.testing.expectEqual(@as(i32, 200), placement.y);
}

test "placeTooltip: near-corner alignment follows the near corner" {
    // Source in the bottom-right quadrant, `above` fits (clearance = y = 1700 >
    // tooltip height 400). Right-align: shared edge runs from the source's
    // top-right corner leftward.
    const source_x: i32 = 3400;
    const source_w: i32 = 256;
    const placement = placeTooltip(.{ .x = source_x, .y = 1700 }, source_w, 256, 400, 400);
    try std.testing.expectEqual(@as(i32, 1700 - 400), placement.y); // flush above
    // right-aligned: panel right edge == source right edge
    try std.testing.expectEqual(source_x + source_w, placement.x + 400);
}

test "placeTooltip: nothing fits → falls back to top preference (above), clamped" {
    // Tooltip taller than the screen on every side's cross axis and larger
    // than the vertical clearance. Falls back to `above` and clamps on screen.
    const placement = placeTooltip(.{ .x = 1000, .y = 1000 }, 256, 256, 5000, 5000);
    // Clamped to [0, screen - tooltip] on both axes (tooltip > screen →
    // screen - tooltip is negative, clamp yields 0).
    try std.testing.expectEqual(@as(i32, 0), placement.x);
    try std.testing.expectEqual(@as(i32, 0), placement.y);
}

test "placeTooltip: shared edge — panel sits flush on the chosen side" {
    // Top preference `above` fits: the panel's bottom edge must equal the
    // source's top edge (shared edge, not just a corner touch).
    const source_y: i32 = 1500;
    const tooltip_h: i32 = 500;
    const placement = placeTooltip(.{ .x = 1500, .y = source_y }, 256, 256, 400, tooltip_h);
    try std.testing.expectEqual(source_y, placement.y + tooltip_h);
}
