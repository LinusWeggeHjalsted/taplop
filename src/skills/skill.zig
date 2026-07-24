const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Entity = types.Entity;
const SkillId = types.SkillId;
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
    /// Used for highlighting tiles when the player is targeting, or passed through to selectTarget for enemies.
    /// should return null if not uses_targeting, or maybe event handler should just skip directly to useSkill in that case without ever calling this function
    get_valid_targets_fn: *const fn (
        caster_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Vector2,

    /// AI priority: how much an enemy wants to use this skill right now.
    /// Higher value = higher priority, 0 if shouldn't be used now, max float if it's a skill to be used that doesn't end turn (i.e. cast all max priority skills one at a time until there's a turn-ending skill to cast)
    priority_fn: *const fn (
        caster_index: u32,
        game_state: GameState,
    ) f32,

    /// AI target selection - enemy picks a target after getValidTargets provides the options
    /// should return null if valid_targets is null
    select_target_fn: *const fn (
        caster_index: u32,
        valid_targets: ?[]const Vector2,
        game_state: GameState,
    ) ?Vector2,

    /// sets flags for targetable tiles to allow player input
    player_prepare_skill_fn: *const fn (
        caster_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?Event,

    /// queues skill effects.
    use_skill_fn: *const fn (
        caster_index: u32,
        target: ?Vector2,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) []const Event,

    // --- convenience methods that call the function pointers ---

    pub fn getValidTargets(
        self: Skill,
        caster_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Vector2 {
        return self.get_valid_targets_fn(caster_index, game_state, allocator);
    }

    pub fn priority(
        self: Skill,
        caster_index: u32,
        game_state: GameState,
    ) f32 {
        return self.priority_fn(caster_index, game_state);
    }

    pub fn selectTarget(
        self: Skill,
        caster_index: u32,
        valid_targets: ?[]const Vector2,
        game_state: GameState,
    ) ?Vector2 {
        return self.select_target_fn(caster_index, valid_targets, game_state);
    }

    pub fn playerPrepareSkill(
        self: Skill,
        caster_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?Event {
        return self.player_prepare_skill_fn(caster_index, game_state, allocator);
    }

    pub fn useSkill(
        self: Skill,
        caster_index: u32,
        target: ?Vector2,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) []const Event {
        return self.use_skill_fn(caster_index, target, game_state, allocator);
    }
};
