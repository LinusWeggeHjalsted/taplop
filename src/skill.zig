const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");

const Vector2 = types.Vector2;
const GameState = state.GameState;
const Event = events.Event;
const Entity = types.Entity;
const SkillId = types.SkillId;
const SkillType = types.SkillType;

const skill_id_count = @typeInfo(types.SkillId).@"enum".fields.len;

/// The pass-scoped AI evaluation frame — the ONE mechanism behind
/// consultation-safe rating and its performance: within one
/// enemy_turn_attack re-evaluation pass the game state is frozen, so each
/// skill's options are computed AT MOST ONCE (memoized in `results`) and
/// every nested consultation reuses them. Recursion is cut by
/// `in_progress`: a skill whose aiOptions is currently being computed
/// (transitively) answers NOTHING to nested questions about it — which is
/// also the correct semantics, e.g. an enhancer scanning beneficiaries
/// must not count itself. Fresh frame per pass (never on GameState, never
/// serialized — replay-safe by construction). Options slices are
/// arena-owned (they outlive the frame). See DESIGN → Architecture
/// (AI rating scale + AI cast selection).
pub const EvalFrame = struct {
    in_progress: std.enums.EnumSet(types.SkillId),
    results: [skill_id_count]?[]const AiOption,

    pub fn empty() EvalFrame {
        return .{
            .in_progress = std.enums.EnumSet(types.SkillId).initEmpty(),
            .results = [_]?[]const AiOption{null} ** skill_id_count,
        };
    }
};

/// One AI candidate cast: `target` is what gets passed to useSkill (null =
/// self-cast / self-centered), `priority` is its rating (higher = better).
/// 0-rated casts are not emitted.
pub const AiOption = struct {
    target: ?Vector2,
    priority: u32,
};

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
    /// reach (ai_threat.zig computeMaxDamageRange); control, mobility,
    /// and buff skills are false. Required (no default): a forgotten flag
    /// on a future damaging skill would silently under-report threat.
    deals_damage: bool,

    /// Whether the skill's effect region is centered on the caster
    /// (a point-blank area of effect): the AoE hits around the caster's own
    /// position, not a targeted tile. Drives AI movement-mode selection
    /// (ai_movement.zig): an entity with an OFF-COOLDOWN offensive
    /// point-blank skill seeks the tile with the most hostiles in radius.
    /// Defaults false — a forgotten flag only makes the AI dumber (it walks
    /// instead of cluster-seeking), it does not corrupt any mechanic.
    point_blank_area_of_effect: bool = false,

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

    /// AI options: enumerate this skill's meaningful casts as
    /// (target, rating) pairs, best-first. Replaces the old
    /// priority/selectTarget pair — the rating and the chosen target are
    /// one decision, so they cannot disagree (the old split's seams: bash
    /// rated "any colliding target" while selection attacked another;
    /// flash strike rated one landing tile and landed on another).
    /// The handler (enemy_turn_attack) picks the global best, breaking
    /// ties by option order (the skill's own deterministic ordering), then
    /// skill slot order. Result lives in `allocator` (consumed
    /// synchronously by the handler).
    ///
    /// RATING SCALE (value units): priority ≈ the cast's value in units of
    /// a plain 1x hit — 0 = don't cast, 1 = a plain attack, +1 per
    /// significant bonus (a conditional damage multiplier, a stun landing
    /// on a non-stunned target, collision damage, a control effect worth a
    /// hit; lifesteal only when the caster is below half health). AoE
    /// ratings sum per target (helpers.aoePriority / aoeKnockbackPriority);
    /// global riders (e.g. Flash Strike's teleport) count once. Ties mean
    /// equal value — the handler's slot-order tiebreak then prefers the
    /// skill further left. See DESIGN → Architecture (AI rating scale).
    ///
    /// PORTING NOTE: the Unity original INVERTS priority (lower number =
    /// higher priority, -1 = don't use). When porting a skill, FLIP the
    /// numbers to higher = better (Unity -1 = don't cast = emit nothing;
    /// Unity 0..N -> a positive rating). Turn-ending vs non-turn-ending is
    /// decided by skill_type at the call site, not by the rating —
    /// non-ending and ending skills are chosen from separate pools
    /// (enemy_turn_attack), so cantrip ratings only compete with each
    /// other; equal ratings keep bar order (the handler replaces only on
    /// strictly-greater).
    ///
    /// `frame` is the pass-scoped evaluation frame (EvalFrame above):
    /// consult other skills' options THROUGH it
    /// (ai_select.optionsFor) — never call another skill's aiOptions
    /// directly — so evaluations are memoized per pass and cycles are cut
    /// mechanically. A skill that doesn't consult others simply ignores it.
    ai_options_fn: *const fn (
        caster_index: u32,
        game_state: GameState,
        weapon_type_definitions: types.WeaponTypeDefinitions,
        allocator: std.mem.Allocator,
        frame: *EvalFrame,
    ) []const AiOption,

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

    pub fn aiOptions(
        self: Skill,
        caster_index: u32,
        game_state: GameState,
        weapon_type_definitions: types.WeaponTypeDefinitions,
        allocator: std.mem.Allocator,
        frame: *EvalFrame,
    ) []const AiOption {
        return self.ai_options_fn(caster_index, game_state, weapon_type_definitions, allocator, frame);
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
