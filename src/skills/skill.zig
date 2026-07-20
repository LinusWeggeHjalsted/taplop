const types = @import("../types.zig");

const Vec2 = types.Vec2;
const GameState = types.GameState;
const EntityInfo = types.EntityInfo;
const SkillType = types.SkillType;

/// The interface that every skill in the game implements.
/// Each skill file (e.g. slice.zig) returns one of these from its `define()` function.
pub const Skill = struct {
    // --- metadata ---
    name: []const u8,
    skill_type: SkillType,
    description: []const u8,
    uses_targeting: bool,

    // --- skill stats ---
    range: ?u32, // used for skills with targeting
    radius: ?u32, // used by aoe skills
    distance: ?u32, // used by knockback and retreat
    skill_duration: ?u32, // used by enchantments, curses, and other lingering effects
    stun_duration: ?u32, // used by stunning skills, decoupled from skill_duration for balance reasons
    cooldown: ?u32, // used by all skills, except first skill on each weapon

    // --- function pointers (the "interface") ---

    /// Returns which tiles are valid targets for this skill, given the caster's position.
    /// Used for highlighting tiles when the player is targeting, or passed through to select_target for enemies.
    /// should return null if not uses_targeting, or maybe event handler should just skip directly to use_skill in that case without ever calling this function
    get_valid_targets_fn: *const fn (caster_index: u32, state: GameState) ?[]const Vec2,

    /// AI priority: how much an enemy wants to use this skill right now.
    /// Higher value = higher priority, 0 if shouldn't be used now, max float if it's a skill to be used that doesn't end turn (i.e. cast all max priority skills one at a time until there's a turn-ending skill to cast)
    priority_fn: *const fn (caster_index: u32, state: GameState) f32,

    /// AI target selection - enemy picks a target after get_valid_targets provides the options
    /// should return null if valid_targets is null
    select_target_fn: *const fn (caster_index: u32, valid_targets: ?[]const Vec2, state: GameState) ?Vec2,

    /// sets flags for targetable tiles to allow player input
    player_prepare_skill_fn: *const fn (caster_index: u32, state: GameState) ?GameEvent,

    /// queues skill effects.
    use_skill_fn: *const fn (caster_index: u32, target: ?Vec2, state: GameState) []const GameEvent,

    // --- convenience methods that call the function pointers ---

    pub fn get_valid_targets(self: Skill, caster_index: u32, state: GameState) ?[]const Vec2 {
        return self.get_valid_targets_fn(caster_index, state);
    }

    pub fn priority(self: Skill, caster_index: u32, state: GameState) f32 {
        return self.priority_fn(caster_index, state);
    }

    pub fn select_target(self: Skill, caster_index: u32, valid_targets: ?[]const Vec2, state: GameState) ?Vec2 {
        return self.select_target_fn(caster_index, valid_targets, state);
    }

    pub fn player_prepare_skill(self: Skill, caster_index: u32, state: GameState) GameEvent {
        return self.player_prepare_skill_fn(caster_index, state);
    }

    pub fn use_skill(self: Skill, caster_index: u32, target: ?Vec2, state: GameState) []const GameEvent {
        return self.use_skill_fn(caster_index, target, state);
    }
};
