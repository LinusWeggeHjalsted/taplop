//! Tier 4 handler tests — turn-flow orchestrators. `turn_start` (cooldown
//! reduction, effect duration decrement, stun gating, player/enemy branch),
//! `turn_end` (enemy ordering by distance-then-entity_index — the determinism
//! rule; turn counters), `player_turn_move`/`player_turn_attack` (phase set +
//! auto-skip out of combat), and the player-action orchestrators
//! (`player_move_action`/`player_skip_move`/`player_skip_attack`/
//! `player_cancel_skill`/`player_use_skill` fan-out). See TODO → Tech debt.

const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const event_handlers = @import("event_handlers.zig");
const player_handlers = @import("handlers/player.zig");
const event_push = @import("event_push.zig");
const test_harness = @import("test_harness.zig");

const Harness = test_harness.Harness;
const runToIdle = test_harness.runToIdle;
const levelEntity = test_harness.levelEntity;
const Entity = types.Entity;
const Vector2 = types.Vector2;
const Event = events.Event;
const LevelEvent = events.LevelEvent;
const SkillId = types.SkillId;
const EffectId = types.EffectId;

/// A 5x5 tile grid.
const five_by_five = [_]Vector2{
    .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 0 },
    .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 }, .{ .x = 4, .y = 1 },
    .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 2 }, .{ .x = 4, .y = 2 },
    .{ .x = 0, .y = 3 }, .{ .x = 1, .y = 3 }, .{ .x = 2, .y = 3 }, .{ .x = 3, .y = 3 }, .{ .x = 4, .y = 3 },
    .{ .x = 0, .y = 4 }, .{ .x = 1, .y = 4 }, .{ .x = 2, .y = 4 }, .{ .x = 3, .y = 4 }, .{ .x = 4, .y = 4 },
};

/// Push one level event onto the stack (no drain). The caller inspects
/// `event_stack` or calls `processEvent` manually for ordering tests.
fn pushOne(history: *state.GameStateHistory, event: LevelEvent) void {
    event_push.pushEvents(&history.current_state, &.{.{ .level_event = event }}, history.current_arena.allocator());
}

/// Push one player-input event onto the stack (no drain). Same as `pushOne`
/// but for `PlayerInputEvent` (the player orchestrator variants that moved
/// out of LevelEvent).
fn pushPlayerInput(history: *state.GameStateHistory, event: events.PlayerInputEvent) void {
    event_push.pushEvents(&history.current_state, &.{.{ .player_input_event = event }}, history.current_arena.allocator());
}

/// Run exactly one processEvent step (pops the top, runs its handler, leaves
/// any pushed events on the stack). For orchestrator/ordering tests that need
/// to inspect the stack without draining.
fn stepOnce(history: *state.GameStateHistory) void {
    event_handlers.processEvent(history);
}

// ───────────────────────── turn_start ─────────────────────────

test "turn_start: reduces all skill cooldowns by 1" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    levelEntity(&history, 0).skill_cooldowns.set(.stab, 3);
    levelEntity(&history, 0).skill_cooldowns.set(.slice, 1);
    pushOne(&history, .{ .turn_start = .{ .entity_index = 0 } });
    stepOnce(&history); // runs turn_start, pushes player_turn_move
    try testing.expectEqual(@as(u32, 2), levelEntity(&history, 0).skill_cooldowns.get(.stab));
    try testing.expectEqual(@as(u32, 0), levelEntity(&history, 0).skill_cooldowns.get(.slice));
}

test "turn_start: decrements effect durations and pushes end_effect for expired" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const effects = try backing.allocator().dupe(types.Effect, &.{
        .{ .effect_id = .stone_form, .duration = 2, .additive_effect_modifiers = .{} },
        .{ .effect_id = .reflect, .duration = 1, .additive_effect_modifiers = .{} },
    });
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .active_effects = effects }},
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_start = .{ .entity_index = 0 } });
    stepOnce(&history);
    // Stone Form (duration 2 -> 1) stays; Reflect (duration 1 -> expired) is
    // removed. end_effect is pushed onto the stack but the handler hasn't run
    // yet (we only stepped once) — the active_effects list is rebuilt by
    // turn_start BEFORE the end_effect events run, so Reflect is already gone.
    try testing.expectEqual(@as(usize, 1), levelEntity(&history, 0).active_effects.len);
    try testing.expectEqual(EffectId.stone_form, levelEntity(&history, 0).active_effects[0].effect_id);
    try testing.expectEqual(@as(u32, 1), levelEntity(&history, 0).active_effects[0].duration);
}

test "turn_start: stunned entity skips turn (pushes turn_end, not the move event)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 1, .position = .{ .x = 0, .y = 0 }, .stun_duration = 2 }},
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_start = .{ .entity_index = 0 } });
    stepOnce(&history);
    // Stun reduced by 1 (2 -> 1); stack top is turn_end (not enemy_turn_move).
    try testing.expectEqual(@as(u32, 1), levelEntity(&history, 0).stun_duration);
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try testing.expect(history.current_state.event_stack[0] == .level_event);
    try testing.expect(history.current_state.event_stack[0].level_event == .turn_end);
}

test "turn_start: player (entity 0) pushes player_turn_move" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_start = .{ .entity_index = 0 } });
    stepOnce(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try testing.expect(history.current_state.event_stack[0].level_event == .player_turn_move);
}

test "turn_start: enemy (entity != 0) pushes enemy_turn_move" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 4, .y = 4 } },
            .{ .team = 1, .position = .{ .x = 0, .y = 0 } },
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_start = .{ .entity_index = 1 } });
    stepOnce(&history);
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try testing.expect(history.current_state.event_stack[0].level_event == .enemy_turn_move);
}

test "turn_start: dead entity is a no-op (no events pushed)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 0, .max_health = 10 }},
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_start = .{ .entity_index = 0 } });
    stepOnce(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

// ───────────────────────── turn_end (enemy ordering) ─────────────────────────

test "turn_end: player turn_end pushes enemies sorted by distance, closest on top" {
    // Two enemies at different distances from the player. turn_end pushes:
    //   array = [player_turn_start, enemy_far, enemy_near]
    //   stack top = enemy_near (processed first = closest first).
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } }, // player
            .{ .team = 1, .position = .{ .x = 4, .y = 0 }, .is_active = true }, // dist 4 (far)
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .is_active = true }, // dist 1 (near)
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_end = .{ .entity_index = 0 } });
    stepOnce(&history);
    // Stack: [player_turn_start, enemy_far_turn_start, enemy_near_turn_start]
    // Top (last) = enemy_near; bottom (first) = player_turn_start.
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 3), stack.len);
    try testing.expect(stack[0].level_event == .turn_start); // player at bottom
    try testing.expectEqual(@as(u32, 0), stack[0].level_event.turn_start.entity_index);
    try testing.expect(stack[1].level_event == .turn_start); // far enemy
    try testing.expectEqual(@as(u32, 1), stack[1].level_event.turn_start.entity_index);
    try testing.expect(stack[2].level_event == .turn_start); // near enemy on top
    try testing.expectEqual(@as(u32, 2), stack[2].level_event.turn_start.entity_index);
}

test "turn_end: distance ties break by entity_index (lowest first = closest to top)" {
    // Two enemies equidistant from the player: index 1 at (1,0), index 2 at
    // (0,1), both distance 1. The sort breaks ties by entity_index ascending,
    // so index 1 is "closer" → pushed later → on top (processed first).
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .is_active = true }, // dist 1, index 1
            .{ .team = 1, .position = .{ .x = 0, .y = 1 }, .is_active = true }, // dist 1, index 2
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_end = .{ .entity_index = 0 } });
    stepOnce(&history);
    // Sort: both dist 1, tie → entity_index asc → [index 1, index 2].
    // Reverse for stack: [player, index_2, index_1] → top = index_1.
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(u32, 1), stack[2].level_event.turn_start.entity_index); // top
    try testing.expectEqual(@as(u32, 2), stack[1].level_event.turn_start.entity_index);
}

test "turn_end: inactive enemies are skipped in the round" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .is_active = true },
            .{ .team = 1, .position = .{ .x = 2, .y = 0 }, .is_active = false }, // inactive
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_end = .{ .entity_index = 0 } });
    stepOnce(&history);
    // Only the player + the active enemy: stack = [player, enemy_1].
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 2), stack.len);
    try testing.expectEqual(@as(u32, 1), stack[1].level_event.turn_start.entity_index);
}

test "turn_end: dead enemies are skipped" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .is_active = true, .current_health = 0, .max_health = 10 },
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_end = .{ .entity_index = 0 } });
    stepOnce(&history);
    // Only the player's turn_start on the stack.
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 1), stack.len);
    try testing.expectEqual(@as(u32, 0), stack[0].level_event.turn_start.entity_index);
}

test "turn_start: increments turns_spent on the live mission" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    history.current_state.mission = .{ .turns_spent = 5 };
    pushOne(&history, .{ .turn_start = .{ .entity_index = 0 } });
    stepOnce(&history);
    try testing.expectEqual(@as(u32, 6), history.current_state.mission.?.turns_spent);
}

test "turn_end: non-player turn_end pushes nothing (next turn_start is already on the stack)" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 4, .y = 4 } },
            .{ .team = 1, .position = .{ .x = 0, .y = 0 } },
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_end = .{ .entity_index = 1 } });
    stepOnce(&history);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

// ───────────────────────── player_turn_move / player_turn_attack ─────────────────────────

test "player_turn_move: sets turn_phase to player_move" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .speed = 1 }},
        &five_by_five,
    ));
    pushOne(&history, .player_turn_move);
    stepOnce(&history);
    try testing.expectEqual(types.TurnPhase.player_move, history.current_state.level.?.turn_phase.?);
    // Highlights refreshed for the player's reachable tiles.
    try testing.expect(history.current_state.level.?.highlighted_tiles.len > 0);
}

test "player_turn_attack: auto-skips to turn_end when no active enemies" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 4, .y = 4 }, .is_active = false }, // no active enemies
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .player_turn_attack = .{} });
    stepOnce(&history);
    // auto_skip_attack_step_out_of_combat defaults true; no active enemies →
    // pushes turn_end (stack has one event), turn_phase stays null.
    try testing.expectEqual(@as(usize, 1), history.current_state.event_stack.len);
    try testing.expect(history.current_state.event_stack[0].level_event == .turn_end);
    try testing.expectEqual(@as(?types.TurnPhase, null), history.current_state.level.?.turn_phase);
}

test "player_turn_attack: enters player_attack when active enemies exist" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .is_active = true },
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .player_turn_attack = .{} });
    stepOnce(&history);
    try testing.expectEqual(types.TurnPhase.player_attack, history.current_state.level.?.turn_phase.?);
    try testing.expectEqual(@as(usize, 0), history.current_state.event_stack.len);
}

test "player_turn_attack: force_attack_step overrides auto-skip even with no active enemies" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 4, .y = 4 }, .is_active = false },
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .player_turn_attack = .{ .force_attack_step = true } });
    stepOnce(&history);
    // Override → enters player_attack despite no active enemies.
    try testing.expectEqual(types.TurnPhase.player_attack, history.current_state.level.?.turn_phase.?);
}

// ───────────────────────── player-action orchestrators ─────────────────────────

test "player_move_action: fans out move_entity + clear_highlights + player_turn_attack" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 }, .speed = 2 }},
        &five_by_five,
    ));
    pushPlayerInput(&history, .{ .player_move_action = .{ .destination = .{ .x = 2, .y = 0 } } });
    stepOnce(&history);
    // LIFO: array = [player_turn_attack, clear_highlights, move_entity]
    // stack top (last) = move_entity (runs first).
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 3), stack.len);
    try testing.expect(stack[0].level_event == .player_turn_attack); // bottom
    try testing.expect(stack[1].level_event == .clear_highlights);
    try testing.expect(stack[2].level_event == .move_entity); // top, runs first
    try testing.expectEqual(@as(i32, 2), stack[2].level_event.move_entity.destination.x);
}

test "player_skip_move: fans out clear_highlights + player_turn_attack" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    pushPlayerInput(&history, .{ .player_skip_move = .{} });
    stepOnce(&history);
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 2), stack.len);
    try testing.expect(stack[0].level_event == .player_turn_attack); // bottom
    try testing.expect(stack[1].level_event == .clear_highlights); // top
}

test "player_skip_attack: fans out turn_end + clear_highlights + clear_prepared_skill" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    pushPlayerInput(&history, .player_skip_attack);
    stepOnce(&history);
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 3), stack.len);
    try testing.expect(stack[0].level_event == .turn_end); // bottom
    try testing.expect(stack[1].level_event == .clear_highlights);
    try testing.expect(stack[2].level_event == .clear_prepared_skill); // top
}

test "player_cancel_skill: fans out clear_highlights + clear_prepared_skill" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    pushPlayerInput(&history, .player_cancel_skill);
    stepOnce(&history);
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 2), stack.len);
    try testing.expect(stack[0].level_event == .clear_highlights); // bottom
    try testing.expect(stack[1].level_event == .clear_prepared_skill); // top
}

test "player_use_skill: turn-ending skill fans out turn_end + use_skill + clear + clear" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .main_hand_weapon = .{ .weapon_type = .dagger, .weapon_damage = 1 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &five_by_five,
    ));
    // stab is a weapon_skill (turn-ending).
    pushPlayerInput(&history, .{ .player_use_skill = .{ .skill_id = .stab, .target = .{ .x = 1, .y = 0 } } });
    stepOnce(&history);
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 4), stack.len);
    try testing.expect(stack[0].level_event == .turn_end); // bottom (runs last)
    try testing.expect(stack[1].level_event == .use_skill);
    try testing.expect(stack[2].level_event == .clear_highlights);
    try testing.expect(stack[3].level_event == .clear_prepared_skill); // top (runs first)
}

test "player_use_skill: non-turn-ending skill omits turn_end" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .equipped_utility_skills = blk: {
                var skills: [types.utility_skill_count]?SkillId = .{null} ** types.utility_skill_count;
                skills[0] = .blink;
                break :blk skills;
            } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &five_by_five,
    ));
    // blink is a cantrip (non-turn-ending).
    pushPlayerInput(&history, .{ .player_use_skill = .{ .skill_id = .blink, .target = .{ .x = 2, .y = 0 } } });
    stepOnce(&history);
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 3), stack.len);
    try testing.expect(stack[0].level_event == .use_skill); // bottom
    try testing.expect(stack[1].level_event == .clear_highlights);
    try testing.expect(stack[2].level_event == .clear_prepared_skill); // top
    // No turn_end in the stack.
    for (stack) |event| try testing.expect(event.level_event != .turn_end);
}

test "player_skip_move_to_skill: prepare branch fans out prepare + player_turn_attack(forced) + clear" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    pushPlayerInput(&history, .{ .player_skip_move_to_skill = .{
        .skill_id = .stab,
        .prepare = true,
    } });
    stepOnce(&history);
    // LIFO: array = [player_prepare_skill, player_turn_attack, clear_highlights]
    // stack top (last) = clear_highlights (runs first).
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 3), stack.len);
    try testing.expect(stack[0].player_input_event == .player_prepare_skill); // bottom
    try testing.expect(stack[1].level_event == .player_turn_attack);
    try testing.expect(stack[2].level_event == .clear_highlights); // top, runs first
    // The attack step is always forced so auto_skip_attack_step_out_of_combat
    // can't end the turn before the prepared skill fires.
    try testing.expect(stack[1].level_event.player_turn_attack.force_attack_step);
}

test "player_skip_move_to_skill: use branch fans out use + player_turn_attack(forced) + clear" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    pushPlayerInput(&history, .{ .player_skip_move_to_skill = .{
        .skill_id = .stab,
        .target = .{ .x = 1, .y = 0 },
        .prepare = false,
    } });
    stepOnce(&history);
    const stack = history.current_state.event_stack;
    try testing.expectEqual(@as(usize, 3), stack.len);
    try testing.expect(stack[0].player_input_event == .player_use_skill); // bottom
    try testing.expect(stack[1].level_event == .player_turn_attack);
    try testing.expect(stack[2].level_event == .clear_highlights); // top, runs first
    try testing.expect(stack[1].level_event.player_turn_attack.force_attack_step);
}

// ───────────────────────── clone system ─────────────────────────
// See DESIGN → Clones (clone system). cloneIsStrictlyBetter is a pure
// helper; save_clone_info / harvest_clones are SuperEvents pushed by the
// end_level last-level branch (tested via direct push here).

const Materials = types.Materials;
const Clone = types.Clone;
const SuperEvent = events.SuperEvent;

fn pushSuper(history: *state.GameStateHistory, event: SuperEvent) void {
    event_push.pushEvents(&history.current_state, &.{.{ .super_event = event }}, history.current_arena.allocator());
}

test "cloneIsStrictlyBetter: all rates strictly higher -> true" {
    const new_m: Materials = .{ .wood = 20, .metal = 30, .leather = 0, .cloth = 0, .knowledge = 0 };
    const old_m: Materials = .{ .wood = 10, .metal = 10, .leather = 0, .cloth = 0, .knowledge = 0 };
    // 4 turns each: rates 5,7 vs 2,2 -> strict gain; zeros tie.
    try testing.expect(player_handlers.cloneIsStrictlyBetter(4, new_m, 4, old_m));
}

test "cloneIsStrictlyBetter: one rate worse -> false" {
    const new_m: Materials = .{ .wood = 20, .metal = 5, .leather = 0, .cloth = 0, .knowledge = 0 };
    const old_m: Materials = .{ .wood = 10, .metal = 20, .leather = 0, .cloth = 0, .knowledge = 0 };
    // 4 turns: wood 5>2 (gain), metal 1<5 (worse) -> false.
    try testing.expect(!player_handlers.cloneIsStrictlyBetter(4, new_m, 4, old_m));
}

test "cloneIsStrictlyBetter: all rates equal -> false (no strict gain)" {
    const new_m: Materials = .{ .wood = 10, .metal = 10, .leather = 0, .cloth = 0, .knowledge = 0 };
    const old_m: Materials = .{ .wood = 10, .metal = 10, .leather = 0, .cloth = 0, .knowledge = 0 };
    // 4 turns: all rates equal -> no strict gain -> false (offer manual overwrite).
    try testing.expect(!player_handlers.cloneIsStrictlyBetter(4, new_m, 4, old_m));
}

test "cloneIsStrictlyBetter: gains on some, ties on rest -> true" {
    const new_m: Materials = .{ .wood = 20, .metal = 10, .leather = 0, .cloth = 0, .knowledge = 0 };
    const old_m: Materials = .{ .wood = 10, .metal = 10, .leather = 0, .cloth = 0, .knowledge = 0 };
    // 4 turns: wood 5>2 (gain), metal 2==2 (tie), rest 0==0 -> true.
    try testing.expect(player_handlers.cloneIsStrictlyBetter(4, new_m, 4, old_m));
}

test "save_clone_info: appends when no existing clone for that uuid" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    pushSuper(&history, .{ .save_clone_info = .{
        .mission_uuid = "uuid-A",
        .mission_name = "Mission A",
        .total_turns = 5,
        .total_materials = .{ .wood = 10, .metal = 0, .leather = 0, .cloth = 0, .knowledge = 0 },
    } });
    runToIdle(&history);
    const clones = history.current_state.player_data.clones;
    try testing.expectEqual(@as(usize, 1), clones.len);
    try testing.expectEqualStrings("uuid-A", clones[0].mission_uuid);
    try testing.expectEqualStrings("Mission A", clones[0].name);
    try testing.expectEqual(@as(u32, 5), clones[0].turns_to_complete);
    try testing.expectEqual(@as(u32, 10), clones[0].materials_collected.wood);
}

test "save_clone_info: replaces existing clone for the same uuid" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const pre_clones = try backing.allocator().dupe(Clone, &.{.{
        .mission_uuid = "uuid-A",
        .name = "Old A",
        .turns_to_complete = 10,
        .materials_collected = .{ .wood = 5, .metal = 0, .leather = 0, .cloth = 0, .knowledge = 0 },
    }});
    var history = harness.newHistory(null);
    history.current_state.player_data.clones = pre_clones;
    pushSuper(&history, .{ .save_clone_info = .{
        .mission_uuid = "uuid-A",
        .mission_name = "Mission A",
        .total_turns = 4,
        .total_materials = .{ .wood = 20, .metal = 0, .leather = 0, .cloth = 0, .knowledge = 0 },
    } });
    runToIdle(&history);
    const clones = history.current_state.player_data.clones;
    try testing.expectEqual(@as(usize, 1), clones.len);
    try testing.expectEqualStrings("uuid-A", clones[0].mission_uuid);
    try testing.expectEqualStrings("Mission A", clones[0].name);
    try testing.expectEqual(@as(u32, 4), clones[0].turns_to_complete);
    try testing.expectEqual(@as(u32, 20), clones[0].materials_collected.wood);
}

test "save_clone_info: leaves other clones untouched" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const pre_clones = try backing.allocator().dupe(Clone, &.{
        .{ .mission_uuid = "uuid-A", .name = "A", .turns_to_complete = 10, .materials_collected = .{} },
        .{ .mission_uuid = "uuid-B", .name = "B", .turns_to_complete = 20, .materials_collected = .{ .metal = 5 } },
    });
    var history = harness.newHistory(null);
    history.current_state.player_data.clones = pre_clones;
    pushSuper(&history, .{ .save_clone_info = .{
        .mission_uuid = "uuid-A",
        .mission_name = "A new",
        .total_turns = 3,
        .total_materials = .{ .wood = 9, .metal = 0, .leather = 0, .cloth = 0, .knowledge = 0 },
    } });
    runToIdle(&history);
    const clones = history.current_state.player_data.clones;
    try testing.expectEqual(@as(usize, 2), clones.len);
    // uuid-A replaced; uuid-B preserved exactly.
    try testing.expectEqualStrings("uuid-B", clones[1].mission_uuid);
    try testing.expectEqual(@as(u32, 20), clones[1].turns_to_complete);
    try testing.expectEqual(@as(u32, 5), clones[1].materials_collected.metal);
    try testing.expectEqualStrings("uuid-A", clones[0].mission_uuid);
    try testing.expectEqual(@as(u32, 3), clones[0].turns_to_complete);
}

test "harvest_clones: pays out rate * turns from each clone" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Two clones: rate wood = 10/5 = 2/turn; rate metal = 6/3 = 2/turn.
    const pre_clones = try backing.allocator().dupe(Clone, &.{
        .{ .mission_uuid = "u1", .name = "A", .turns_to_complete = 5, .materials_collected = .{ .wood = 10 } },
        .{ .mission_uuid = "u2", .name = "B", .turns_to_complete = 3, .materials_collected = .{ .metal = 6 } },
    });
    var history = harness.newHistory(null);
    history.current_state.player_data.clones = pre_clones;
    pushSuper(&history, .{ .harvest_clones = .{ .turns_spent = 4 } });
    runToIdle(&history);
    // wood: 2*4 = 8; metal: 2*4 = 8.
    const materials = history.current_state.player_data.materials;
    try testing.expectEqual(@as(u32, 8), materials.wood);
    try testing.expectEqual(@as(u32, 8), materials.metal);
    try testing.expectEqual(@as(u32, 0), materials.leather);
}

test "harvest_clones: zero turns_spent is a no-op" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const pre_clones = try backing.allocator().dupe(Clone, &.{
        .{ .mission_uuid = "u1", .name = "A", .turns_to_complete = 5, .materials_collected = .{ .wood = 10 } },
    });
    var history = harness.newHistory(null);
    history.current_state.player_data.clones = pre_clones;
    pushSuper(&history, .{ .harvest_clones = .{ .turns_spent = 0 } });
    runToIdle(&history);
    const materials = history.current_state.player_data.materials;
    try testing.expectEqual(@as(u32, 0), materials.wood);
}

test "harvest_clones: skips clones with zero turns_to_complete" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const pre_clones = try backing.allocator().dupe(Clone, &.{
        .{ .mission_uuid = "u1", .name = "A", .turns_to_complete = 0, .materials_collected = .{ .wood = 10 } },
        .{ .mission_uuid = "u2", .name = "B", .turns_to_complete = 5, .materials_collected = .{ .wood = 10 } },
    });
    var history = harness.newHistory(null);
    history.current_state.player_data.clones = pre_clones;
    pushSuper(&history, .{ .harvest_clones = .{ .turns_spent = 5 } });
    runToIdle(&history);
    // Only u2 contributes: rate 2 * 5 = 10.
    try testing.expectEqual(@as(u32, 10), history.current_state.player_data.materials.wood);
}

// ───────────────────────── mission stat accumulators ─────────────────────────
// See DESIGN → Clones (clone system). tiles_moved increments in move_entity,
// skills_used in use_skill — both player-only, gated on mission non-null.

fn pushLevel(history: *state.GameStateHistory, event: LevelEvent) void {
    event_push.pushEvents(&history.current_state, &.{.{ .level_event = event }}, history.current_arena.allocator());
}

test "move_entity: player tiles_moved accumulates on the mission" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &five_by_five,
    ));
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushLevel(&history, .{ .move_entity = .{ .entity_index = 0, .destination = .{ .x = 1, .y = 0 } } });
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 1), history.current_state.mission.?.tiles_moved);
}

test "move_entity: non-player move does not accumulate tiles_moved" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 2, .y = 0 } },
        },
        &five_by_five,
    ));
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushLevel(&history, .{ .move_entity = .{ .entity_index = 1, .destination = .{ .x = 3, .y = 0 } } });
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 0), history.current_state.mission.?.tiles_moved);
}

test "use_skill: player skills_used accumulates on the mission" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 } },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 }, .current_health = 10, .max_health = 10 },
        },
        &five_by_five,
    ));
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushLevel(&history, .{ .use_skill = .{ .caster_index = 0, .skill_id = .stab, .target = .{ .x = 1, .y = 0 } } });
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 1), history.current_state.mission.?.skills_used);
}

test "use_skill: non-player skill does not accumulate skills_used" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .current_health = 10, .max_health = 10 },
            .{ .team = 1, .position = .{ .x = 1, .y = 0 } },
        },
        &five_by_five,
    ));
    history.current_state.mission = .{ .uuid = "test-uuid" };
    pushLevel(&history, .{ .use_skill = .{ .caster_index = 1, .skill_id = .stab, .target = .{ .x = 0, .y = 0 } } });
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 0), history.current_state.mission.?.skills_used);
}

test "computeHarvest: pure payout matches harvest_clones handler" {
    const clones = [_]Clone{
        .{ .mission_uuid = "u1", .name = "A", .turns_to_complete = 5, .materials_collected = .{ .wood = 10 } },
        .{ .mission_uuid = "u2", .name = "B", .turns_to_complete = 3, .materials_collected = .{ .metal = 6 } },
    };
    const payout = player_handlers.computeHarvest(&clones, 4);
    // wood: (10/5)*4 = 8; metal: (6/3)*4 = 8.
    try testing.expectEqual(@as(u32, 8), payout.wood);
    try testing.expectEqual(@as(u32, 8), payout.metal);
    try testing.expectEqual(@as(u32, 0), payout.leather);
}

test "computeHarvest: multiply-before-divide pays out fractional-rate clones" {
    // Regression: a clone whose materials < turns_to_complete has a
    // fractional per-turn rate. Dividing first (materials / turns) truncates
    // the rate to 0 and yields nothing; multiplying first pays out the
    // cross-product before the single truncating divide. Mirrors the real
    // Beginnings clone (11 wood / 49 turns) that harvested 0.
    const clones = [_]Clone{
        .{ .mission_uuid = "u1", .name = "A", .turns_to_complete = 49, .materials_collected = .{ .wood = 11, .metal = 25 } },
    };
    const payout = player_handlers.computeHarvest(&clones, 30);
    // wood: (11*30)/49 = 330/49 = 6; metal: (25*30)/49 = 750/49 = 15.
    try testing.expectEqual(@as(u32, 6), payout.wood);
    try testing.expectEqual(@as(u32, 15), payout.metal);
    try testing.expectEqual(@as(u32, 0), payout.leather);
}

// ───────────────────────── player_overwrite_clone orchestrator ─────────────────────────
// See DESIGN → Clones (clone system). The overlay button pushes this; the
// handler reads last_completed_mission and pushes save_clone_info with the
// run's snapshot, replacing the existing clone.

test "player_overwrite_clone: replaces the existing clone with the run snapshot" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const pre_clones = try backing.allocator().dupe(Clone, &.{.{
        .mission_uuid = "uuid-A",
        .name = "Old A",
        .turns_to_complete = 10,
        .materials_collected = .{ .wood = 5 },
    }});
    var history = harness.newHistory(null);
    history.current_state.player_data.clones = pre_clones;
    history.current_state.last_completed_mission = .{
        .uuid = "uuid-A",
        .name = "Mission A",
        .path = "path/a",
        .turns_spent = 4,
        .converted_materials = .{ .wood = 20 },
        .overwrite_offered = true,
    };
    pushPlayerInput(&history, .player_overwrite_clone);
    runToIdle(&history);
    const clones = history.current_state.player_data.clones;
    try testing.expectEqual(@as(usize, 1), clones.len);
    try testing.expectEqualStrings("uuid-A", clones[0].mission_uuid);
    try testing.expectEqual(@as(u32, 4), clones[0].turns_to_complete);
    try testing.expectEqual(@as(u32, 20), clones[0].materials_collected.wood);
}

test "player_overwrite_clone: no-op when no completed mission" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    const pre_clones = try backing.allocator().dupe(Clone, &.{.{
        .mission_uuid = "uuid-A",
        .name = "Old A",
        .turns_to_complete = 10,
        .materials_collected = .{ .wood = 5 },
    }});
    var history = harness.newHistory(null);
    history.current_state.player_data.clones = pre_clones;
    // No last_completed_mission set — handler returns early.
    pushPlayerInput(&history, .player_overwrite_clone);
    runToIdle(&history);
    const clones = history.current_state.player_data.clones;
    try testing.expectEqual(@as(usize, 1), clones.len);
    try testing.expectEqual(@as(u32, 10), clones[0].turns_to_complete);
}

test "turn_end: Stone Form on_end_turn heal runs BEFORE next turn_start (LIFO order)" {
    // Regression: on_end_turn events (Stone Form heal) were pushed BEFORE the
    // round-building turn_starts, so on the LIFO stack the turn_starts sat on
    // top and ran first — the heal fired at the START of the player's next
    // turn, not the END of the current one. Fix: push round events first,
    // then on_end_turn events so the heal lands on top.
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    // Player with Stone Form active, 20 max health → heal = 4.
    const effects = try backing.allocator().alloc(types.Effect, 1);
    effects[0] = .{ .effect_id = .stone_form, .duration = 3 };
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{
            .{ .team = 0, .position = .{ .x = 0, .y = 0 }, .max_health = 20, .current_health = 10, .active_effects = effects },
            .{ .team = 1, .position = .{ .x = 4, .y = 4 }, .is_active = true },
        },
        &five_by_five,
    ));
    pushOne(&history, .{ .turn_end = .{ .entity_index = 0 } });
    // After running to idle, the heal should have applied (current_health
    // 10 + 4 = 14) and the round should have played out (enemy turn + next
    // player turn_start). The key assertion: the heal ran as part of the
    // player's turn_end, not deferred to the next turn_start.
    runToIdle(&history);
    try testing.expectEqual(@as(u32, 14), levelEntity(&history, 0).current_health);
}

// ───────────────────────── player_load_save ─────────────────────────

test "player_load_save: pushes the meta load_save with the picked path" {
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = Harness.init(backing.allocator());
    var history = harness.newHistory(null);

    // Main-menu start state (the browser only exists there).
    try testing.expectEqual(state.Screen.main_menu, history.current_state.screen);

    pushPlayerInput(&history, .{ .player_load_save = .{ .save_path = "saves/save_x.txt" } });
    stepOnce(&history);

    // The orchestrator ran and left the machinery event on top of the stack
    // (LIFO: one child pushed, not yet drained; beneath it sits the start
    // state's open_main_menu).
    try testing.expectEqual(@as(usize, 2), history.current_state.event_stack.len);
    const top = history.current_state.event_stack[1];
    try testing.expectEqual(std.meta.activeTag(top), .meta_event);
    try testing.expectEqualStrings("saves/save_x.txt", top.meta_event.load_save.save_path);
}
