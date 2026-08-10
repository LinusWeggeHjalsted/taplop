const std = @import("std");
const types = @import("../types.zig");
const state = @import("../state.zig");
const events = @import("../events.zig");

const Vector2 = types.Vector2;
const AdditiveEffectModifiers = types.AdditiveEffectModifiers;
const GameState = state.GameState;
const Event = events.Event;

/// The interface that every effect (enchantment, curse, etc.) implements.
/// Each effect file returns one of these from its `define()` function.
///
/// Effects are active on an entity for a duration, providing passive stat
/// modifiers and triggering events in response to game actions.
///
/// All callback function pointers follow the same pattern:
///   (entity_index, game_state, allocator) -> ?[]const Event
/// They return null if no events should be pushed, or a slice of events.
pub const Effect = struct {
    name: []const u8,
    description: []const u8,
    additive_effect_modifiers: AdditiveEffectModifiers,

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

/// Use this to fill all callback fields, then override the ones you need.
/// Since Zig doesn't have struct update syntax for function pointers at
/// comptime in all cases, this serves as documentation of the default.
pub const no_op = &noOp;
