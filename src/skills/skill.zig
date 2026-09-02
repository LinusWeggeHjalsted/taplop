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
    /// Whether the skill's useSkill deals damage (directly or via
    /// collision/knockback). Drives AI threat math — an enemy's damaging
    /// reach (skills/threat.zig computeMaxDamageRange); control, mobility,
    /// and buff skills are false. Required (no default): a forgotten flag
    /// on a future damaging skill would silently under-report threat.
    deals_damage: bool,

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
    /// Higher value = higher priority; 0 means the skill should not be used now.
    /// Turn-ending vs non-turn-ending is decided by skill_type at the call site
    /// (see enemy_turn_attack), not by the priority magnitude.
    /// `weapon_type_definitions` is the session's weapon-type → skills
    /// mapping — needed by skills whose evaluation reads other entities'
    /// skill bars (the defensive skills' threat model, skills/threat.zig);
    /// most skills ignore it.
    ///
    /// PORTING NOTE: the Unity original INVERTS this (lower number = higher
    /// priority, -1 = don't use). When porting a skill, FLIP the numbers to
    /// higher = better, 0 = don't use (e.g. Unity 2/3 -> ziglop 3/2).
    /// Unity also used 0 as a catch-all for non-turn-ending skills (cantrips/
    /// enchantments), iterating them in skill-bar order. Here turn-ending is
    /// decided separately by skill_type, so those get REAL positive priorities
    /// (Unity -1 -> 0 don't-use; Unity 0 -> a positive value). Non-ending and
    /// ending skills are chosen from separate pools (enemy_turn_attack), so
    /// cantrip priorities only compete with each other; equal values keep
    /// bar order (the AI replaces only on strictly-greater).
    priority_fn: *const fn (
        caster_index: u32,
        game_state: GameState,
        weapon_type_definitions: types.WeaponTypeDefinitions,
    ) u32,

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

    /// pushes skill effects.
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
        weapon_type_definitions: types.WeaponTypeDefinitions,
    ) u32 {
        return self.priority_fn(caster_index, game_state, weapon_type_definitions);
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
