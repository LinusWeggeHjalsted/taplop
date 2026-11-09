//! Utility-skill policy - the single source for which skills are legal on
//! the utility bar: anything but weapon skills (spells, cantrips,
//! enchantments, curses). Weapon skills belong to the equipped weapon's
//! three slots, never the bar. Read by the parsers (a weapon skill in
//! slot_4..8 or inside a skill tome is warned + dropped), the editor
//! (the picker's option list + commit validation), and the player equip
//! path. See DESIGN → Architecture → Level Editor → Editor UI layout →
//! Inspector fields.

const std = @import("std");
const types = @import("types.zig");
const lookups = @import("generated_lookups.zig");

/// Whether `skill_id` may occupy a utility bar slot. A skill without a
/// definition is not offerable (false).
pub fn isUtilitySkill(skill_id: types.SkillId) bool {
    const definition = lookups.getSkillDefinition(skill_id) orelse return false;
    return definition.skill_type != .weapon_skill;
}

/// Every utility-eligible skill, in enum order - the picker's option list
/// (and any future "what can be a tome" check). Comptime-evaluated: the
/// skill definitions are comptime-known, so new skills join automatically.
pub const utility_skill_ids: []const types.SkillId = build: {
    var ids: []const types.SkillId = &.{};
    for (@typeInfo(types.SkillId).@"enum".field_names) |field_name| {
        const skill_id: types.SkillId = @field(types.SkillId, field_name);
        if (isUtilitySkill(skill_id)) {
            ids = ids ++ [_]types.SkillId{skill_id};
        }
    }
    break :build ids;
};

test "utility-skill policy: weapon skills excluded, the rest eligible" {
    try std.testing.expect(!isUtilitySkill(.slice));
    try std.testing.expect(!isUtilitySkill(.spinblade));
    try std.testing.expect(isUtilitySkill(.blink));
    try std.testing.expect(isUtilitySkill(.stone_form));
    // No snapshot count - the list grows with every new spell/cantrip/
    // enchantment/curse, and a hardcoded number was churn on every landing.
    // The structural coverage (one picker cell per offered skill) lives in
    // the editor skill-picker test, derived from this same list.
    for (utility_skill_ids) |skill_id| {
        try std.testing.expect(isUtilitySkill(skill_id));
    }
}
