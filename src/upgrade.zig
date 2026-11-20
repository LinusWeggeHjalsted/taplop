//! The wealth-gap upgrade price model (DESIGN → Gear Upgrading): the tier
//! frontier, the per-rung cost over the wealth curve, the salvage-ratio
//! split of a cost across material wallets, and the starter-stat
//! derivation from the new-player template's gear. Pure integer/rational
//! arithmetic over the session-resident `types.UpgradeModel` +
//! `SalvageDefinition` - no floats (the gameplay-integers rule), no
//! allocation. The design-time audit script re-derives the same demand
//! curve for tuning (see TODO → Gear Upgrading).

const std = @import("std");
const types = @import("types.zig");

const UpgradeModel = types.UpgradeModel;
const ItemStatField = types.ItemStatField;
const SalvageDefinition = types.SalvageDefinition;

const material_type_count = @typeInfo(types.MaterialType).@"enum".field_names.len;

/// The b-line tier fraction, 75% - the frontier's knee (the design's
/// T(3) anchor). Structural like `itemStatMax`, not config.
const b_line_tier_fraction_numerator: u32 = 3;
const b_line_tier_fraction_denominator: u32 = 4;

/// A frontier mission as an exact non-negative rational.
const FrontierMission = struct {
    numerator: u64,
    denominator: u64,
};

/// The tier frontier: the mission at which `value` of `stat` is the
/// on-pace tier. Piecewise-linear in the tier fraction, one rule for
/// every stat (DESIGN → Gear Upgrading → The cost ladder):
///
///   m(f) = b_line · (f − f_s) / (0.75 − f_s)                   f ≤ 0.75
///   m(f) = b_line + (campaign − b_line) · (f − 0.75) / 0.25    f ≥ 0.75
///
/// with f = value/max and f_s = starter/max. All three anchors exact:
/// the starter at m = 0, the 75% b-line at m = b_line, the 100% tier at
/// m = campaign. The rationals below are the fraction rule scaled
/// through f = value/max (so the denominators are `max`-shaped, not
/// normalized - callers only ever consume the pair through the gap
/// arithmetic).
pub fn frontierMission(
    model: UpgradeModel,
    stat: ItemStatField,
    value: u32,
) FrontierMission {
    const maximum = types.itemStatMax(stat);
    const starter = model.starter_stat_values[@backingInt(stat)];
    if (value <= starter) return .{ .numerator = 0, .denominator = 1 };

    // The segment is chosen by the tier fraction: f ≤ 0.75 exactly when
    // 4·value ≤ 3·maximum. u64 arithmetic throughout - the public entry
    // takes arbitrary u32 values.
    if (4 * @as(u64, value) <= 3 * @as(u64, maximum)) {
        // m = b_line · 4·(value − starter) / (3·maximum − 4·starter). A
        // starter at or above 75% of max is a degenerate configuration
        // no real stat reaches; fail fast rather than misprice.
        const denominator: i64 = 3 * @as(i64, maximum) - 4 * @as(i64, starter);
        if (denominator <= 0) @panic("upgrade frontier degenerate: starter stat at or above the 75% tier");
        return .{
            .numerator = 4 * @as(u64, model.b_line_mission_count) * (value - starter),
            .denominator = @intCast(denominator),
        };
    }
    // m = b_line + (campaign − b_line) · (4·value − 3·maximum) / maximum.
    return .{
        .numerator = @as(u64, model.b_line_mission_count) * maximum +
            @as(u64, model.campaign_mission_count - model.b_line_mission_count) *
                (4 * @as(u64, value) - 3 * @as(u64, maximum)),
        .denominator = maximum,
    };
}

/// The per-rung cost of v → v+1 in parts: α_thousandths · K ·
/// (W(m(v+1)) − W(m(v))), round-half-up to an integer (DESIGN → Gear
/// Upgrading → The cost ladder). K is the number of entries in the
/// salvage split; an item kind with no split prices at 0 (the degenerate
/// empty-salvage case). u128 intermediates - the loader's bounds on R /
/// the mission counts / α keep every product far inside it.
pub fn rungCostTotalParts(
    model: UpgradeModel,
    stat: ItemStatField,
    salvage: SalvageDefinition,
    current_value: u32,
) u64 {
    const start = frontierMission(model, stat, current_value);
    const end = frontierMission(model, stat, current_value + 1);

    // ΔW = R·(m_end·(m_end+1) − m_start·(m_start+1)) / 2, over the common
    // denominator (d_start·d_end)².
    const n1: u128 = start.numerator;
    const d1: u128 = start.denominator;
    const n2: u128 = end.numerator;
    const d2: u128 = end.denominator;
    const gap_numerator: u128 = n2 * (n2 + d2) * d1 * d1 - n1 * (n1 + d1) * d2 * d2;
    const gap_denominator: u128 = 2 * d1 * d1 * d2 * d2;

    const alpha: u128 = model.alpha_thousandths[@backingInt(stat)];
    const wallets: u128 = salvage.splits.len;
    const raw_numerator: u128 =
        alpha * wallets * model.materials_per_mission_per_wallet * gap_numerator;
    const raw_denominator: u128 = 1000 * gap_denominator;

    // Round-half-up of raw_numerator / raw_denominator.
    const total: u128 = (2 * raw_numerator + raw_denominator) / (2 * raw_denominator);
    return std.math.cast(u64, total) orelse std.math.maxInt(u64);
}

/// The rung cost split across wallets in the salvage ratio: floor each
/// material's exact share of the (integer) budget, then hand the
/// difference to the largest fractional remainders, ties broken by
/// `MaterialType` order (deterministic - DESIGN → Gear Upgrading → The
/// cost ladder, the integer-rounding rule). Materials absent from the
/// salvage split cost nothing.
pub fn rungCostSplit(
    model: UpgradeModel,
    stat: ItemStatField,
    salvage: SalvageDefinition,
    current_value: u32,
) types.Materials {
    var cost: types.Materials = .{};
    const budget = rungCostTotalParts(model, stat, salvage, current_value);
    if (budget == 0 or salvage.splits.len == 0) return cost;

    // Aggregate the split entries per material (a duplicated material
    // line in a salvage definition just adds to that material's share).
    var per_material_parts: [material_type_count]u64 = @splat(0);
    var ratio_total: u64 = 0;
    for (salvage.splits) |split| {
        per_material_parts[@backingInt(split.material)] += split.parts;
        ratio_total += split.parts;
    }
    if (ratio_total == 0) return cost;

    // Floor each carrying material's exact share of the budget (u128:
    // the budget and the per-material ratio parts are both u64, so the
    // product can exceed it).
    var parts: [material_type_count]u64 = @splat(0);
    var distributed: u64 = 0;
    for (0..material_type_count) |ordinal| {
        const share: u128 = @as(u128, budget) * per_material_parts[ordinal];
        parts[ordinal] = @intCast(share / ratio_total);
        distributed += parts[ordinal];
    }

    // The remainder count is always below the number of carrying
    // materials (each floor loses under one part), so one extra per
    // material suffices. Award by largest fractional remainder
    // (budget·parts mod ratio_total), ties by material order - the
    // first ordinal with a strictly greater remainder wins a tie, and
    // the scan visits ordinals in order.
    var awarded: [material_type_count]bool = @splat(false);
    var remaining = budget - distributed;
    while (remaining > 0) : (remaining -= 1) {
        var best_ordinal: usize = 0;
        var best_remainder: u64 = 0;
        var found = false;
        for (0..material_type_count) |ordinal| {
            if (awarded[ordinal] or per_material_parts[ordinal] == 0) continue;
            const remainder: u128 = (@as(u128, budget) * per_material_parts[ordinal]) % ratio_total;
            if (!found or remainder > best_remainder) {
                found = true;
                best_ordinal = ordinal;
                best_remainder = @intCast(remainder);
            }
        }
        if (!found) break;
        awarded[best_ordinal] = true;
        parts[best_ordinal] += 1;
    }

    for (0..material_type_count) |ordinal| {
        const bounded = std.math.cast(u32, parts[ordinal]) orelse std.math.maxInt(u32);
        switch (@as(types.MaterialType, @fromBackingInt(@intCast(ordinal)))) {
            .wood => cost.wood +|= bounded,
            .metal => cost.metal +|= bounded,
            .leather => cost.leather +|= bounded,
            .cloth => cost.cloth +|= bounded,
            .knowledge => cost.knowledge +|= bounded,
        }
    }
    return cost;
}

/// Whether `materials` covers `cost` wallet by wallet.
pub fn canAffordMaterials(
    materials: types.Materials,
    cost: types.Materials,
) bool {
    return materials.wood >= cost.wood and
        materials.metal >= cost.metal and
        materials.leather >= cost.leather and
        materials.cloth >= cost.cloth and
        materials.knowledge >= cost.knowledge;
}

/// s_stat: the standard starting value per stat, derived from the
/// new-player template's EQUIPPED gear (DESIGN → Gear Upgrading) - the
/// max over the pieces that carry the stat (the shipped starter pieces
/// agree; max is the deterministic convention). The inventory is
/// excluded: carried, not standard.
pub fn starterStatValuesFromGear(
    player_data: types.PlayerData,
) [types.item_stat_count]u32 {
    var values: [types.item_stat_count]u32 = @splat(0);
    const equipped = [_]?types.Item{
        if (player_data.main_hand_weapon) |weapon| types.Item{ .weapon = weapon } else null,
        if (player_data.off_hand_weapon) |weapon| types.Item{ .weapon = weapon } else null,
        if (player_data.amulet) |amulet| types.Item{ .amulet = amulet } else null,
        if (player_data.coat) |coat| types.Item{ .coat = coat } else null,
        if (player_data.gloves) |gloves| types.Item{ .gloves = gloves } else null,
        if (player_data.pants) |pants| types.Item{ .pants = pants } else null,
        if (player_data.boots) |boots| types.Item{ .boots = boots } else null,
    };
    for (equipped) |maybe_item| {
        const item = maybe_item orelse continue;
        for (types.itemStatSet(item)) |stat| {
            // The stat comes from itemStatSet, so the item carries it.
            const value = types.itemStatValue(item, stat).?;
            if (value > values[@backingInt(stat)]) values[@backingInt(stat)] = value;
        }
    }
    return values;
}

// ============================================================
// Tests
// ============================================================

const test_model: UpgradeModel = .{
    .materials_per_mission_per_wallet = 27,
    .b_line_mission_count = 3,
    .campaign_mission_count = 66,
    .alpha_thousandths = blk: {
        var values: [types.item_stat_count]u32 = @splat(0);
        values[@backingInt(ItemStatField.weapon_damage)] = 300;
        values[@backingInt(ItemStatField.spell_damage)] = 600;
        values[@backingInt(ItemStatField.health_bonus)] = 54;
        values[@backingInt(ItemStatField.defense_bonus)] = 54;
        values[@backingInt(ItemStatField.damage_bonus)] = 54;
        values[@backingInt(ItemStatField.pickup_radius_bonus)] = 54;
        values[@backingInt(ItemStatField.speed_bonus)] = 54;
        break :blk values;
    },
    .starter_stat_values = blk: {
        var values: [types.item_stat_count]u32 = @splat(0);
        values[@backingInt(ItemStatField.weapon_damage)] = 3;
        values[@backingInt(ItemStatField.spell_damage)] = 3;
        values[@backingInt(ItemStatField.health_bonus)] = 1;
        break :blk values;
    },
};

const sword_salvage = SalvageDefinition{ .splits = &.{
    .{ .material = .wood, .parts = 1 },
    .{ .material = .metal, .parts = 3 },
} };

test "upgrade frontier: the three anchors are exact and the tail landings match the design" {
    // Starter (sword, s = 3) at mission 0.
    try std.testing.expectEqual(
        FrontierMission{ .numerator = 0, .denominator = 1 },
        frontierMission(test_model, .weapon_damage, 3),
    );
    // The mid segment: m(7) = 48/18 = 8/3 (the b-line value, still mid -
    // its fraction 0.7 is below the 0.75 knee).
    try std.testing.expectEqual(
        FrontierMission{ .numerator = 48, .denominator = 18 },
        frontierMission(test_model, .weapon_damage, 7),
    );
    // The tail: m(8) = 156/10 = 15.6 (the design's "≈ 16" landing),
    // m(10) = 660/10 = 66 (campaign completion).
    try std.testing.expectEqual(
        FrontierMission{ .numerator = 156, .denominator = 10 },
        frontierMission(test_model, .weapon_damage, 8),
    );
    try std.testing.expectEqual(
        FrontierMission{ .numerator = 660, .denominator = 10 },
        frontierMission(test_model, .weapon_damage, 10),
    );
    // Speed (max 2, s = 0): 1 is mid (m = 12/6 = 2), 2 is tail at 66.
    try std.testing.expectEqual(
        FrontierMission{ .numerator = 12, .denominator = 6 },
        frontierMission(test_model, .speed_bonus, 1),
    );
    try std.testing.expectEqual(
        FrontierMission{ .numerator = 132, .denominator = 2 },
        frontierMission(test_model, .speed_bonus, 2),
    );
}

test "upgrade prices: the sword worked example matches DESIGN (escalates with the income curve)" {
    // The DESIGN worked-example table: 3→4 ≈ 9 parts (2 wood + 7 metal),
    // 6→7 ≈ 31, 7→8 ≈ 2.0k, 9→10 ≈ 22k - all exact here.
    try std.testing.expectEqual(
        @as(u64, 9),
        rungCostTotalParts(test_model, .weapon_damage, sword_salvage, 3),
    );
    try std.testing.expectEqual(
        types.Materials{ .wood = 2, .metal = 7 },
        rungCostSplit(test_model, .weapon_damage, sword_salvage, 3),
    );
    try std.testing.expectEqual(
        @as(u64, 31),
        rungCostTotalParts(test_model, .weapon_damage, sword_salvage, 6),
    );
    try std.testing.expectEqual(
        types.Materials{ .wood = 8, .metal = 23 },
        rungCostSplit(test_model, .weapon_damage, sword_salvage, 6),
    );
    try std.testing.expectEqual(
        @as(u64, 2018),
        rungCostTotalParts(test_model, .weapon_damage, sword_salvage, 7),
    );
    try std.testing.expectEqual(
        @as(u64, 22004),
        rungCostTotalParts(test_model, .weapon_damage, sword_salvage, 9),
    );

    // Strict escalation across the whole ladder (the W-quadratic property).
    var previous: u64 = 0;
    var value: u32 = 3;
    while (value < 10) : (value += 1) {
        const parts = rungCostTotalParts(test_model, .weapon_damage, sword_salvage, value);
        try std.testing.expect(parts > previous);
        previous = parts;
    }
}

test "upgrade prices: the spell ladder concentrates on knowledge; speed ties break by material order" {
    const amulet_salvage = SalvageDefinition{ .splits = &.{
        .{ .material = .knowledge, .parts = 1 },
    } };
    // Spell 3→4 at α = 600, K = 1: the same 15-part gap, all knowledge.
    try std.testing.expectEqual(
        @as(u64, 9),
        rungCostTotalParts(test_model, .spell_damage, amulet_salvage, 3),
    );
    try std.testing.expectEqual(
        types.Materials{ .knowledge = 9 },
        rungCostSplit(test_model, .spell_damage, amulet_salvage, 3),
    );

    // Speed 0→1 ≈ 9 parts (the cheapest rung family); the 1:1 split
    // tie (both remainders 1) goes to leather - the earlier MaterialType.
    const boots_salvage = SalvageDefinition{ .splits = &.{
        .{ .material = .cloth, .parts = 1 },
        .{ .material = .leather, .parts = 1 },
    } };
    try std.testing.expectEqual(
        @as(u64, 9),
        rungCostTotalParts(test_model, .speed_bonus, boots_salvage, 0),
    );
    try std.testing.expectEqual(
        types.Materials{ .leather = 5, .cloth = 4 },
        rungCostSplit(test_model, .speed_bonus, boots_salvage, 0),
    );
    // Speed 1→2 spans the widest window in the game (m = 2 → 66): the
    // biggest cloth+leather purchase (59,616 wealth gap at α = 54).
    try std.testing.expectEqual(
        @as(u64, 6439),
        rungCostTotalParts(test_model, .speed_bonus, boots_salvage, 1),
    );
    try std.testing.expectEqual(
        types.Materials{ .leather = 3220, .cloth = 3219 },
        rungCostSplit(test_model, .speed_bonus, boots_salvage, 1),
    );
}

test "upgrade prices: an empty salvage split prices at zero; affordability is wallet-by-wallet" {
    const empty_salvage = SalvageDefinition{ .splits = &.{} };
    try std.testing.expectEqual(
        @as(u64, 0),
        rungCostTotalParts(test_model, .weapon_damage, empty_salvage, 3),
    );
    try std.testing.expectEqual(
        types.Materials{},
        rungCostSplit(test_model, .weapon_damage, empty_salvage, 3),
    );

    const cost = rungCostSplit(test_model, .weapon_damage, sword_salvage, 6);
    try std.testing.expect(canAffordMaterials(.{ .wood = 8, .metal = 23 }, cost));
    try std.testing.expect(!canAffordMaterials(.{ .wood = 8, .metal = 22 }, cost));
}

test "upgrade starter stats: derived from equipped gear, max convention, inventory excluded" {
    // The shipped starter gear: weapons 3, amulet 3, health 1, minors 0.
    var player_data: types.PlayerData = .{};
    player_data.main_hand_weapon = .{
        .name = "Starter Sword",
        .weapon_type = .sword,
        .weapon_damage = 3,
    };
    player_data.off_hand_weapon = .{
        .name = "Starter Shield",
        .weapon_type = .shield,
        .weapon_damage = 3,
    };
    player_data.amulet = .{ .name = "Starter Amulet", .spell_damage = 3 };
    player_data.coat = .{ .name = "Starter Coat", .defense_bonus = 0, .health_bonus = 1 };
    player_data.gloves = .{ .name = "Starter Gloves", .damage_bonus = 0, .health_bonus = 1 };
    player_data.pants = .{ .name = "Starter Pants", .pickup_radius_bonus = 0, .health_bonus = 1 };
    player_data.boots = .{ .name = "Starter Boots", .speed_bonus = 0, .health_bonus = 1 };
    var derived = starterStatValuesFromGear(player_data);
    try std.testing.expectEqual(@as(u32, 3), derived[@backingInt(ItemStatField.weapon_damage)]);
    try std.testing.expectEqual(@as(u32, 3), derived[@backingInt(ItemStatField.spell_damage)]);
    try std.testing.expectEqual(@as(u32, 1), derived[@backingInt(ItemStatField.health_bonus)]);
    try std.testing.expectEqual(@as(u32, 0), derived[@backingInt(ItemStatField.defense_bonus)]);
    try std.testing.expectEqual(@as(u32, 0), derived[@backingInt(ItemStatField.damage_bonus)]);
    try std.testing.expectEqual(@as(u32, 0), derived[@backingInt(ItemStatField.pickup_radius_bonus)]);
    try std.testing.expectEqual(@as(u32, 0), derived[@backingInt(ItemStatField.speed_bonus)]);

    // A stronger off hand raises the weapon starter (the max convention);
    // inventory contents never count.
    player_data.off_hand_weapon.?.weapon_damage = 5;
    player_data.inventory.slots[0] = .{ .weapon = .{
        .name = "Carried Axe",
        .weapon_type = .axe,
        .weapon_damage = 9,
    } };
    derived = starterStatValuesFromGear(player_data);
    try std.testing.expectEqual(@as(u32, 5), derived[@backingInt(ItemStatField.weapon_damage)]);
}
