const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");

const Vector2 = types.Vector2;
const AdditiveEffectModifiers = types.AdditiveEffectModifiers;
const GameState = state.GameState;
const Event = events.Event;

/// Result of a damage interceptor: the (possibly changed) damage that should
/// continue down the pipeline, plus any events the effect wants to emit
/// (e.g. Reflect emits an attack back at the attacker and sets damage = 0).
pub const DamageInterception = struct {
    damage: u32,
    events: []const Event = &.{},
};

/// The interface that every effect (enchantment, curse, etc.) implements.
///
/// Effects are active on an entity for a duration, providing passive stat
/// modifiers (additive_effect_modifiers) and hooking into game actions.
///
/// An incoming attack resolves in stages; two hook KINDS reflect this:
///   1. attacker's outgoing damage is computed
///   2. defender's INTERCEPTORS transform it (intercept_incoming_damage) —
///      can prevent/reduce/redirect; sees the pre-defense amount
///   3. defender's defense + additive incoming modifiers apply
///   4. damage is applied to health
///   5. defender's REACTORS fire (on_incoming_damage etc.) — know the final
///      applied amount and whether the target died; can only emit events
/// So intercept_* is a TRANSFORM (returns modified damage + events) and the
/// on_* family is REACTIVE (fires after the fact, returns ?[]const Event).
/// All on_* callbacks share the pattern (entity_index, game_state, allocator)
/// -> ?[]const Event.
pub const Effect = struct {
    name: []const u8,
    description: []const u8,
    additive_effect_modifiers: AdditiveEffectModifiers,
    /// Bare sprite stem under assets/effects/ for an overlay drawn on top of
    /// the entity's rendered art while this effect is active (null = no
    /// overlay). Centered on the entity's opaque-art bbox, tinted with the
    /// active theme's lightest color. Drawn as a front_effect_sprite (above
    /// weapons/gear, below the health bar). See DESIGN → Entity & UI Coloring.
    effect_sprite: ?[]const u8 = null,

    // --- damage pipeline: transform stage (see the doc above) ---
    // Runs before defense; may change the damage and/or emit events.
    intercept_incoming_damage_fn: *const fn (
        receiver_index: u32,
        attacker_index: u32,
        incoming_damage: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) DamageInterception,

    // --- lifecycle callbacks ---
    on_effect_creation_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_effect_end_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,

    // --- turn callbacks ---
    on_start_turn_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_end_turn_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,

    // --- combat callbacks ---
    on_attack_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_outgoing_damage_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_incoming_damage_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_outgoing_stun_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_incoming_stun_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_outgoing_effect_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_incoming_effect_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_outgoing_knockback_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_incoming_knockback_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_outgoing_collision_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_incoming_collision_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_retreat_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,
    on_opponent_death_fn: *const fn (
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event,

    // --- convenience methods ---

    pub fn interceptIncomingDamage(
        self: Effect,
        receiver_index: u32,
        attacker_index: u32,
        incoming_damage: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) DamageInterception {
        return self.intercept_incoming_damage_fn(receiver_index, attacker_index, incoming_damage, game_state, allocator);
    }

    pub fn onEffectCreation(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_effect_creation_fn(entity_index, game_state, allocator);
    }

    pub fn onEffectEnd(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_effect_end_fn(entity_index, game_state, allocator);
    }

    pub fn onStartTurn(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_start_turn_fn(entity_index, game_state, allocator);
    }

    pub fn onEndTurn(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_end_turn_fn(entity_index, game_state, allocator);
    }

    pub fn onAttack(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_attack_fn(entity_index, game_state, allocator);
    }

    pub fn onOutgoingDamage(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_outgoing_damage_fn(entity_index, game_state, allocator);
    }

    pub fn onIncomingDamage(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_incoming_damage_fn(entity_index, game_state, allocator);
    }

    pub fn onOutgoingStun(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_outgoing_stun_fn(entity_index, game_state, allocator);
    }

    pub fn onIncomingStun(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_incoming_stun_fn(entity_index, game_state, allocator);
    }

    pub fn onOutgoingEffect(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_outgoing_effect_fn(entity_index, game_state, allocator);
    }

    pub fn onIncomingEffect(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_incoming_effect_fn(entity_index, game_state, allocator);
    }

    pub fn onOutgoingKnockback(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_outgoing_knockback_fn(entity_index, game_state, allocator);
    }

    pub fn onIncomingKnockback(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_incoming_knockback_fn(entity_index, game_state, allocator);
    }

    pub fn onOutgoingCollision(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_outgoing_collision_fn(entity_index, game_state, allocator);
    }

    pub fn onIncomingCollision(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_incoming_collision_fn(entity_index, game_state, allocator);
    }

    pub fn onRetreat(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_retreat_fn(entity_index, game_state, allocator);
    }

    pub fn onOpponentDeath(
        self: Effect,
        entity_index: u32,
        game_state: GameState,
        allocator: std.mem.Allocator,
    ) ?[]const Event {
        return self.on_opponent_death_fn(entity_index, game_state, allocator);
    }
};

/// No-op callback for effects that don't need a particular hook.
fn noOp(_: u32, _: GameState, _: std.mem.Allocator) ?[]const Event {
    return null;
}

/// Default interceptor: passes the damage through unchanged, emits nothing.
fn passIncomingDamage(_: u32, _: u32, incoming_damage: u32, _: GameState, _: std.mem.Allocator) DamageInterception {
    return .{ .damage = incoming_damage };
}

/// Use this for intercept_incoming_damage_fn on effects that don't transform
/// incoming damage (the common case).
pub const pass_incoming_damage = &passIncomingDamage;

/// Use this to fill all callback fields, then override the ones you need.
/// Since Zig doesn't have struct update syntax for function pointers at
/// comptime in all cases, this serves as documentation of the default.
pub const no_op = &noOp;
