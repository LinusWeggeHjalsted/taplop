//! Combat turn-flow + level mechanics: the `.level_event` and
//! `.sub_level_event` arms of processEvent (`handleLevelEvent` /
//! `handleSubLevelEvent`) plus their helpers - entity activation, the
//! damage/heal number anim direction, and the current-mission accessor.
//! The enemy AI range/threat math lives in `ai_threat.zig`.
//! Pure state transforms; sound/anim side effects gate on `!replaying`
//! via `history.session` (see DESIGN → Replay & Side Effects).

const std = @import("std");
const types = @import("../types.zig");
const events = @import("../events.zig");
const state = @import("../state.zig");
const functions = @import("../functions.zig");
const lookups = @import("../generated_lookups.zig");
const threat = @import("../ai_threat.zig");
const movement = @import("../ai_movement.zig");
const ai_select = @import("../ai_select.zig");
const skill_mod = @import("../skill.zig");
const event_push = @import("../event_push.zig");
const shared = @import("shared.zig");

const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Event = events.Event;
const Vector2 = types.Vector2;
const Entity = types.Entity;
const SkillId = types.SkillId;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const weapon_type_count = @typeInfo(types.WeaponType).@"enum".field_names.len;

const pushEvents = event_push.pushEvents;
const getLevelEntity = shared.getLevelEntity;
const refreshMoveHighlights = shared.refreshMoveHighlights;

// Real-time pause inserted between enemy turn actions (before moving, before
// each skill) so enemy turns don't resolve instantly. Not skippable - see the
// wait handling in update() (main.zig).
const turn_flow_wait_milliseconds: u32 = 500;

/// Sign of an i32: -1, 0, or 1. Used to normalize a position delta into a
/// unit direction (one of 8) for the damage-number anim's travel vector.
fn sign(value: i32) i32 {
    return if (value > 0) 1 else if (value < 0) @as(i32, -1) else 0;
}

/// Damage-number travel direction: the normalized attacker→defender delta
/// (one of 8), or top-right `{1, -1}` (same as heals) when the delta is
/// `{0,0}` - i.e. self-damage (attacker == defender, no direction away from
/// an attacker exists). The fallback avoids a divide-by-zero NaN in
/// `view.numberAnimPosition`'s unit-vector math. See AGENTS Animation.
fn damageNumberDirection(attacker_position: Vector2, defender_position: Vector2) Vector2 {
    const dx = sign(defender_position.x - attacker_position.x);
    const dy = sign(defender_position.y - attacker_position.y);
    if (dx == 0 and dy == 0) return .{ .x = 1, .y = -1 };
    return .{ .x = dx, .y = dy };
}

/// Duration of the damage/heal number one-shot anim (matches
/// `view.number_anim_duration_microseconds`). 500ms.
const number_anim_duration_microseconds: u32 = 500_000;

/// Duration of the aggro indicator one-shot anim. 500ms.
const aggro_indicator_duration_microseconds: u32 = 500_000;

/// Activate an entity (flip `is_active = true`) and queue the one-shot
/// aggro indicator above its head. Shared by `aggro_check` and
/// `aggro_in_radius` (Howl) so both paths show the graphic. Gated
/// `!replaying` (same as all anim/sound side effects). See DESIGN → Animation.
fn activateEntity(
    history: *GameStateHistory,
    entity: *types.Entity,
    entity_index: u32,
) void {
    entity.is_active = true;
    if (history.replaying) return;
    // The combat-start sting: one per newly-aggroed enemy (a group aggro
    // stings once per enemy - same moment in practice; tuned with real
    // assets). Every activation path (aggro_check, aggro_in_radius, the
    // hostile-effect arms) routes through here. See DESIGN → Audio.
    history.session.queueSound(history.backing_allocator, .aggro);
    history.session.queueAnim(history.backing_allocator, .{
        .event_index = history.current_event_index - 1,
        .kind = .{ .aggro_indicator = .{ .entity_index = entity_index } },
        .duration_us = aggro_indicator_duration_microseconds,
    });
}

/// Pointer to the current mission, or null if the acting entity isn't the
/// player (entity_index 0) or no mission is active. Shared by the per-event
/// accumulators (tiles_moved, skills_used, damage_dealt/taken, converted
/// materials) so they're one-liners at each call site. See DESIGN → Clones
/// (clone system).
fn playerMissionPtr(current: *GameState) ?*types.Mission {
    if (current.mission) |*mission| return mission;
    return null;
}

/// Push the enemy-turn continuation for "attack from where I stand".
fn pushEnemyAttack(
    current: *GameState,
    entity_index: u32,
    allocator: std.mem.Allocator,
) void {
    pushEvents(current, &.{.{ .level_event = .{ .enemy_turn_attack = .{
        .entity_index = entity_index,
    } } }}, allocator);
}

/// Push the enemy-turn sequence for "move to `destination`, then attack".
/// LIFO order (last pushed runs first): the wait paces the turn, the move
/// lands under it, the attack resolves once the move has completed.
fn pushEnemyMoveThenAttack(
    current: *GameState,
    entity_index: u32,
    destination: Vector2,
    allocator: std.mem.Allocator,
) void {
    pushEvents(current, &.{
        .{ .level_event = .{ .enemy_turn_attack = .{ .entity_index = entity_index } } },
        .{ .level_event = .{ .move_entity = .{ .entity_index = entity_index, .destination = destination } } },
        .{ .meta_event = .{ .wait = .{ .duration_milliseconds = turn_flow_wait_milliseconds } } },
    }, allocator);
}

/// Approach movement (the historical behavior): converge on the nearest
/// hostile, stopping at `computeMinRange` ("close enough to act"). Falls
/// back to reachable tiles when no direct path exists. See DESIGN →
/// Architecture (AI movement modes).
fn enemyApproachTurn(
    current: *GameState,
    weapon_type_definitions: types.WeaponTypeDefinitions,
    entity_index: u32,
    allocator: std.mem.Allocator,
) void {
    const level = &current.level.?;
    const entity = level.entities[entity_index];

    // Find nearest alive entity from a different team
    var nearest_target: ?Vector2 = null;
    var nearest_distance: i32 = std.math.maxInt(i32);
    for (level.entities, 0..) |other_entity, other_index| {
        if (other_index == entity_index) continue;
        if (other_entity.current_health == 0) continue;
        if (other_entity.team == entity.team) continue;
        const distance = functions.chebyshevDistance(entity.position, other_entity.position);
        // Strict < keeps the first at the minimum distance; since
        // we iterate entities in index order, ties resolve to the
        // lowest entity_index (the tiebreaking convention).
        if (distance < nearest_distance) {
            nearest_distance = distance;
            nearest_target = other_entity.position;
        }
    }

    if (nearest_target) |target_position| {
        // Compute min range from off-cooldown skills
        const min_range: i32 = @intCast(threat.computeMinRange(entity, weapon_type_definitions) orelse 1);

        // If already within min range, don't move
        if (nearest_distance <= min_range) {
            // Skip to attack
            pushEnemyAttack(current, entity_index, allocator);
        } else {
            // Try pathfinding to target
            const path = functions.shortestPath(
                level.*,
                entity.position,
                target_position,
                allocator,
            );

            if (path) |path_tiles| {
                const effective_speed = entity.getEffectiveSpeed();

                // Walk along path up to speed steps, but don't get closer than min_range
                var destination = entity.position;
                const max_steps = @min(effective_speed, @as(u32, @intCast(path_tiles.len)));
                for (0..max_steps) |step_index| {
                    const step_position = path_tiles[step_index];
                    // Never step onto the target's own tile: shortestPath
                    // includes the (occupied) destination as its final
                    // tile, so stop before it regardless of min_range.
                    if (step_position.x == target_position.x and step_position.y == target_position.y) break;
                    const distance_from_target = functions.chebyshevDistance(step_position, target_position);
                    if (distance_from_target < min_range) break;
                    destination = step_position;
                }

                if (destination.x != entity.position.x or destination.y != entity.position.y) {
                    pushEnemyMoveThenAttack(current, entity_index, destination, allocator);
                } else {
                    pushEnemyAttack(current, entity_index, allocator);
                }
            } else {
                // No direct path - use reachable tiles, pick closest to target
                const reachable = functions.reachableTiles(
                    level.*,
                    entity.position,
                    entity.getEffectiveSpeed(),
                    allocator,
                );

                // Pick the reachable tile closest to the target
                // (but no nearer than min_range, and only if it
                // improves on the current position). Ties in
                // distance break by the straighter line to the
                // target (same-row chases walk the row), then the
                // (x, y) tile convention so the choice is defined,
                // not scan-order-dependent.
                var best_tile: ?Vector2 = null;
                var best_distance: i32 = nearest_distance;
                for (reachable) |tile| {
                    const distance = functions.chebyshevDistance(tile, target_position);
                    if (distance < min_range) continue;
                    if (distance >= nearest_distance) continue; // must improve on current
                    const is_better = best_tile == null or
                        distance < best_distance or
                        (distance == best_distance and functions.straighterTileBefore(
                            tile,
                            best_tile.?,
                            entity.position,
                            target_position,
                        ));
                    if (is_better) {
                        best_distance = distance;
                        best_tile = tile;
                    }
                }

                if (best_tile) |destination| {
                    pushEnemyMoveThenAttack(current, entity_index, destination, allocator);
                } else {
                    // Can't improve position - just attack
                    pushEnemyAttack(current, entity_index, allocator);
                }
            }
        }
    } else {
        // No targets - skip to turn end
        pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
            .entity_index = entity_index,
        } } }}, allocator);
    }
}

/// Handle a `LevelEvent` - the turn-flow machinery (turn start/end,
/// player/enemy move + attack steps, skill use, highlights). Called from
/// processEvent's `.level_event` arm.
pub fn handleLevelEvent(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    level_event: events.LevelEvent,
) void {
    const current = &history.current_state;
    switch (level_event) {
        .turn_start => |turn| {
            const entity = getLevelEntity(current, turn.entity_index);

            // Skip dead entities
            if (entity.current_health == 0) return;

            // Turn counters, incremented when the player's turn BEGINS:
            // the final turn (walking onto the level exit) never reaches
            // turn_end - end_level's screen transition clears the stack
            // mid-turn - so end-counting silently dropped it. The
            // per-mission counter (turns_spent) lives on the live mission
            // working copy and is discarded with it on exit - it scopes a
            // single playthrough for the mission-complete screen and the
            // validation replay's author medal target. The cumulative
            // lifetime counter (player_data.turns) persists across the
            // campaign for historical stats; it is SKIPPED in editor
            // playtest/validate (discard-semantics - the editor session
            // must not inflate the player's real turn count). Both are
            // direct GameState writes inside an event handler, so they
            // are reproduced on replay. See DESIGN → Custom Missions &
            // Online Services → Turn counters + author medals.
            if (turn.entity_index == 0) {
                if (current.mission) |*mission| {
                    mission.turns_spent += 1;
                }
                if (current.editor == null) {
                    current.player_data.turns += 1;
                }
            }

            // 1. Reduce all skill cooldowns by 1
            inline for (@typeInfo(SkillId).@"enum".field_names) |field_name| {
                const skill_id: SkillId = @field(SkillId, field_name);
                const current_cooldown = entity.skill_cooldowns.get(skill_id);
                if (current_cooldown > 0) {
                    entity.skill_cooldowns.set(skill_id, current_cooldown - 1);
                }
            }

            // 2. Trigger on_start_turn for all active effects, collecting events
            for (entity.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onStartTurn(turn.entity_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }

            // 3. Reduce all effect durations by 1, push end_effect for expired effects
            var remaining_effects: std.ArrayList(types.Effect) = .empty;
            for (entity.active_effects) |active_effect| {
                if (active_effect.duration <= 1) {
                    pushEvents(current, &.{.{ .sub_level_event = .{ .end_effect = .{
                        .entity_index = turn.entity_index,
                        .effect_id = active_effect.effect_id,
                    } } }}, allocator);
                } else {
                    var updated_effect = active_effect;
                    updated_effect.duration -= 1;
                    remaining_effects.append(allocator, updated_effect) catch
                        @panic("failed to append remaining effect");
                }
            }
            entity.active_effects = remaining_effects.toOwnedSlice(allocator) catch
                @panic("failed to allocate remaining effects");

            // 4. If stunned, reduce stun and skip turn
            if (entity.stun_duration > 0) {
                entity.stun_duration -= 1;
                pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                    .entity_index = turn.entity_index,
                } } }}, allocator);
            } else if (turn.entity_index == 0) {
                // Player turn
                pushEvents(current, &.{.{ .level_event = .player_turn_move }}, allocator);
            } else {
                // Enemy turn
                pushEvents(current, &.{.{ .level_event = .{ .enemy_turn_move = .{
                    .entity_index = turn.entity_index,
                } } }}, allocator);
            }
        },
        .turn_end => |turn| {
            const entity = getLevelEntity(current, turn.entity_index);

            // If this is the player's turn ending, push the full next round:
            // all active/alive enemy turn_starts sorted by distance (closest first),
            // plus the next player turn_start at the bottom (processed last).
            //
            // The round events are pushed BEFORE on_end_turn effect hooks
            // so the heals (and any other on_end_turn events) land on TOP
            // of the LIFO stack and run before any turn_starts - i.e. at
            // the END of this turn, not the start of the next. (Swapping
            // the two blocks was the fix for Stone Form healing at the
            // start of the player's next turn instead of the end of the
            // current one; enemy turn_end doesn't build a round so the
            // order is moot there.)
            if (turn.entity_index == 0) {
                const level = &current.level.?;
                level.turn_phase = null;
                const player_position = level.entities[0].position;

                // Collect active, alive non-player entity indices with their distances
                const EntityDistance = struct {
                    entity_index: u32,
                    distance: i32,
                };
                var enemy_distances: std.ArrayList(EntityDistance) = .empty;
                for (level.entities, 0..) |other_entity, entity_index| {
                    if (entity_index == 0) continue;
                    if (other_entity.current_health == 0) continue;
                    if (!other_entity.is_active) continue;
                    enemy_distances.append(allocator, .{
                        .entity_index = @intCast(entity_index),
                        .distance = functions.chebyshevDistance(player_position, other_entity.position),
                    }) catch @panic("failed to append enemy distance");
                }

                // Sort by distance ascending (closest first). std.mem.sort
                // is unstable, so break ties explicitly by entity_index -
                // otherwise equal-distance enemies would take turns in an
                // arbitrary order (see DESIGN → Determinism & Tiebreaking).
                std.mem.sort(EntityDistance, enemy_distances.items, {}, struct {
                    fn lessThan(_: void, a: EntityDistance, b: EntityDistance) bool {
                        if (a.distance != b.distance) return a.distance < b.distance;
                        return a.entity_index < b.entity_index;
                    }
                }.lessThan);

                // Build event batch: player turn_start first (bottom of LIFO),
                // then enemy turn_starts in reverse distance order (farthest first
                // on stack = closest processed first).
                var round_events: std.ArrayList(Event) = .empty;

                // Player's next turn_start goes first in the array (bottom of LIFO stack)
                round_events.append(allocator, .{ .level_event = .{ .turn_start = .{
                    .entity_index = 0,
                } } }) catch @panic("failed to append player turn_start");

                // Enemy turn_starts in reverse order (farthest first in array)
                var reverse_index: usize = enemy_distances.items.len;
                while (reverse_index > 0) {
                    reverse_index -= 1;
                    const enemy = enemy_distances.items[reverse_index];
                    round_events.append(allocator, .{ .level_event = .{ .turn_start = .{
                        .entity_index = enemy.entity_index,
                    } } }) catch @panic("failed to append enemy turn_start");
                }

                pushEvents(current, round_events.items, allocator);
            }
            // Non-player turn_end: no round to build, next turn_start is
            // already on the stack.

            // Trigger on_end_turn for all active effects. Pushed AFTER the
            // round events (above) so on_end_turn events (e.g. Stone Form
            // heal) sit on top of the LIFO stack and run before any
            // turn_starts - at the END of this turn, not the start of the
            // next.
            for (entity.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onEndTurn(turn.entity_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }
        },
        .player_turn_move => {
            const level = &current.level.?;
            level.turn_phase = .player_move;
            refreshMoveHighlights(current, allocator);

            // Event stack is now empty - handleIdleInput will pick up
            // tile clicks and skip actions based on turn_phase.
        },
        .player_turn_attack => |attack| {
            const level = &current.level.?;

            // Auto-skip attack step out of combat: if no active enemies
            // exist, go straight to turn_end. The player can override
            // by holding ctrl at click-time (force_attack_step), which
            // is carried through the orchestrator so the override is
            // replay-safe (recorded in the event).
            if (history.settings.auto_skip_attack_step_out_of_combat and !attack.force_attack_step) {
                if (!level.hasActiveEnemies()) {
                    pushEvents(current, &.{
                        .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
                    }, allocator);
                    return;
                }
            }

            level.turn_phase = .player_attack;

            // Event stack is now empty - handleIdleInput will pick up
            // skill slot selection, skip, and swap weapons based on turn_phase.
        },
        .enemy_turn_move => |enemy_move| {
            const level = &current.level.?;
            const entity = level.entities[enemy_move.entity_index];

            // A dead entity can't take its turn - skip to turn_end to
            // advance the cycle. (Reactive effects like Reflect can
            // kill an entity mid-turn, leaving its turn events already
            // on the stack.)
            if (entity.current_health == 0) {
                pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                    .entity_index = enemy_move.entity_index,
                } } }}, allocator);
                return;
            }

            // Movement mode (ai_movement.zig): cluster-seek when an
            // offensive point-blank skill is ready; kite at min range when
            // the whole kit outranges melee; else approach. A mode
            // destination of null means the mode found nothing to work
            // with this turn (no cluster, nobody in reach) - approach flows
            // through the same path. See DESIGN → Architecture (AI
            // movement modes).
            const entity_index = enemy_move.entity_index;
            const mode = movement.selectMovementMode(
                entity_index,
                current.*,
                history.weapon_type_definitions,
            );
            const destination: ?Vector2 = switch (mode) {
                .approach => null,
                .point_blank_cluster => movement.pointBlankClusterDestination(
                    entity_index,
                    current.*,
                    history.weapon_type_definitions,
                    allocator,
                ),
                .keep_range => movement.keepRangeDestination(
                    entity_index,
                    current.*,
                    history.weapon_type_definitions,
                    allocator,
                ),
            };
            if (destination) |mode_destination| {
                if (mode_destination.x != entity.position.x or mode_destination.y != entity.position.y) {
                    pushEnemyMoveThenAttack(current, entity_index, mode_destination, allocator);
                } else {
                    // The mode's best tile is the entity's own - stand and
                    // attack from here.
                    pushEnemyAttack(current, entity_index, allocator);
                }
            } else {
                enemyApproachTurn(current, history.weapon_type_definitions, entity_index, allocator);
            }
        },
        .enemy_turn_attack => |enemy_attack| {
            const level = &current.level.?;
            const entity = level.entities[enemy_attack.entity_index];

            // A dead entity can't take its turn - skip to turn_end to
            // advance the cycle. (Reactive effects like Reflect can
            // kill an entity mid-turn, leaving its turn events already
            // on the stack.)
            if (entity.current_health == 0) {
                pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                    .entity_index = enemy_attack.entity_index,
                } } }}, allocator);
                return;
            }

            // Fresh evaluation frame for this re-evaluation pass: the
            // game state is frozen within a pass, so every skill's options
            // memoize once (ai_select.optionsFor) and consultation cycles
            // cut mechanically. See DESIGN → Architecture (AI cast
            // selection).
            var frame = skill_mod.EvalFrame.empty();
            const casts = ai_select.bestCasts(
                enemy_attack.entity_index,
                current.*,
                history.weapon_type_definitions,
                allocator,
                &frame,
            );

            // Use non-turn-ending skills first, then turn-ending
            // (the shared selection - see ai_select.zig).
            if (casts.non_ending) |chosen| {
                // Push another enemy_turn_attack after use_skill to re-evaluate.
                // Order (LIFO, last runs first): wait, then skill, then re-evaluate.
                pushEvents(current, &.{
                    .{ .level_event = .{ .enemy_turn_attack = .{
                        .entity_index = enemy_attack.entity_index,
                    } } },
                    .{ .level_event = .{ .use_skill = .{
                        .caster_index = enemy_attack.entity_index,
                        .skill_id = chosen.skill_id,
                        .target = chosen.target,
                    } } },
                    .{ .meta_event = .{ .wait = .{ .duration_milliseconds = turn_flow_wait_milliseconds } } },
                }, allocator);
            } else if (casts.ending) |chosen| {
                // Order (LIFO, last runs first): wait, then skill, then turn_end.
                pushEvents(current, &.{
                    .{ .level_event = .{ .turn_end = .{
                        .entity_index = enemy_attack.entity_index,
                    } } },
                    .{ .level_event = .{ .use_skill = .{
                        .caster_index = enemy_attack.entity_index,
                        .skill_id = chosen.skill_id,
                        .target = chosen.target,
                    } } },
                    .{ .meta_event = .{ .wait = .{ .duration_milliseconds = turn_flow_wait_milliseconds } } },
                }, allocator);
            } else {
                // No usable cast - end turn
                pushEvents(current, &.{.{ .level_event = .{ .turn_end = .{
                    .entity_index = enemy_attack.entity_index,
                } } }}, allocator);
            }
        },
        .use_skill => |use| {
            const entity = getLevelEntity(current, use.caster_index);
            entity.momentum += 1;

            // Every attack is skill-mediated (the player's attack step IS a
            // weapon-skill use; enemies cast through bestCasts), so this is
            // the ONE chain start - the accelerating-wait counter resets
            // here. See DESIGN → Architecture → Skill pacing.
            current.wait_acceleration = 0;

            // Mission stat: skills used by the player. See DESIGN
            // → Clones (clone system).
            if (use.caster_index == 0) {
                if (playerMissionPtr(current)) |mission| {
                    mission.skills_used += 1;
                }
            }

            if (lookups.getSkillDefinition(use.skill_id)) |skill_definition| {
                if (!history.replaying) {
                    // Layered skill cue: base by skill type + texture by
                    // skill id. A missing texture file plays the base alone;
                    // the cantrip/enchantment/curse bases fall back to
                    // `spell` in the backend until their files ship. See
                    // DESIGN → Audio (layered cues).
                    history.session.queueCue(history.backing_allocator, .{
                        .base = types.skillTypeBaseSound(skill_definition.skill_type),
                        .layer = .{ .skill = use.skill_id },
                    });
                    // One-shot anim: show the skill's icon above the
                    // caster for 500ms. `current_event_index - 1` is
                    // this `use_skill` event's index (processEvent
                    // increments before dispatch). See DESIGN →
                    // Animation.
                    history.session.queueAnim(history.backing_allocator, .{
                        .event_index = history.current_event_index - 1,
                        .kind = .{ .skill_icon = .{
                            .entity_index = use.caster_index,
                            .skill_id = use.skill_id,
                        } },
                        .duration_us = 500_000,
                    });
                }
                // Push the skill's events
                const skill_events = skill_definition.useSkill(
                    use.caster_index,
                    use.target,
                    current.*,
                    allocator,
                );
                pushEvents(current, skill_events, allocator);

                // Set cooldown
                if (skill_definition.cooldown) |base_cooldown| {
                    entity.skill_cooldowns.set(
                        use.skill_id,
                        entity.getEffectiveCooldown(base_cooldown),
                    );
                }
            }
        },
        .highlight_tiles => |highlight| {
            const level = &current.level.?;
            level.highlighted_tiles = highlight.tile_positions;
        },
        .clear_highlights => {
            const level = &current.level.?;
            level.highlighted_tiles = &.{};
        },
        .clear_prepared_skill => {
            const level = &current.level.?;
            level.prepared_skill = null;
        },
        .move_entity => |move| {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .move);
            const entity = getLevelEntity(current, move.entity_index);
            entity.position = move.destination;
            entity.momentum += 1;

            // Mission stat: tiles moved by the player. See DESIGN
            // → Clones (clone system).
            if (move.entity_index == 0) {
                if (playerMissionPtr(current)) |mission| {
                    mission.tiles_moved += 1;
                }
            }

            // Push pickup, aggro check, and level-end check after
            // movement. LIFO (last in array runs first), so the
            // array order is: check_level_end, aggro_check,
            // pickup_around → execution: pickup → aggro → level-end.
            // check_level_end runs after aggro_check so newly-aggroed
            // enemies are counted before the win check.
            pushEvents(current, &.{
                .{ .sub_level_event = .{ .check_level_end = .{} } },
                .{ .sub_level_event = .{ .aggro_check = .{} } },
                .{ .sub_level_event = .{ .pickup_around = .{
                    .entity_index = move.entity_index,
                } } },
            }, allocator);
        },
    }
}

/// Handle a `SubLevelEvent` - the combat primitives (attacks, stun,
/// knockback, effects, deaths, pickups, aggro). Called from processEvent's
/// `.sub_level_event` arm.
pub fn handleSubLevelEvent(
    history: *GameStateHistory,
    allocator: std.mem.Allocator,
    sub_level_event: events.SubLevelEvent,
) void {
    const current = &history.current_state;
    switch (sub_level_event) {
        .aggro_check => {
            // Scan every inactive entity; for each, if any opposing
            // entity is within ITS OWN aggro_range, activate it.
            // Self-centric - one event covers the whole level. See
            // DESIGN → Architecture.
            const level = &current.level.?;
            for (level.entities, 0..) |*entity, entity_index| {
                if (entity.current_health == 0) continue;
                if (entity.is_active) continue; // already aggroed

                const aggro_range: i32 = @intCast(entity.aggro_range);
                var sees_opponent = false;
                for (level.entities, 0..) |other_entity, other_index| {
                    if (other_index == entity_index) continue;
                    if (other_entity.current_health == 0) continue;
                    if (other_entity.team == entity.team) continue;
                    if (functions.chebyshevDistance(entity.position, other_entity.position) <= aggro_range) {
                        sees_opponent = true;
                        break;
                    }
                }
                if (sees_opponent) {
                    activateEntity(history, @constCast(entity), @intCast(entity_index));
                }
            }
        },
        .check_level_end => {
            // Lose condition: if the player is dead, the mission is
            // failed - don't check the win condition (a dead player
            // on the exit with no enemies would falsely trigger
            // level completion). The mission_fail overlay is derived
            // from player health in view(); see DESIGN → Architecture.
            const level = &current.level.?;
            if (level.entities[0].current_health == 0) return;

            // Win condition: if the player is on level_end and no
            // active enemies remain, end the level. Decoupled from
            // aggro_check so it can also fire after `death` (killing
            // the last enemy while standing on the exit ends the
            // level without an extra move). Pushed AFTER aggro_check
            // on the stack (LIFO → runs after) so newly-aggroed
            // enemies are counted. See DESIGN → Architecture.
            const player = level.entities[0];
            if (level.level_end) |level_end| {
                if (player.position.x == level_end.x and player.position.y == level_end.y) {
                    if (!level.hasActiveEnemies()) {
                        pushEvents(current, &.{
                            .{ .meta_event = .{ .end_level = .{ .continuation = .default } } },
                        }, allocator);
                    }
                }
            }
        },
        .pickup_around => |pickup| {
            const level = &current.level.?;
            const entity = getLevelEntity(current, pickup.entity_index);
            const pickup_radius: i32 = @intCast(entity.getEffectivePickupRadius(0));

            // Pure CHECK: no mutation here. For each ground stack in
            // range, push a pickup_items event keyed by position; the
            // handler does the transfer. An empty move pushes nothing,
            // so the combat log only sees actual pickups.
            for (level.ground_items) |ground_item_stack| {
                const distance = functions.chebyshevDistance(entity.position, ground_item_stack.position);
                if (distance <= pickup_radius) {
                    pushEvents(current, &.{
                        .{ .sub_level_event = .{ .pickup_items = .{
                            .entity_index = pickup.entity_index,
                            .position = ground_item_stack.position,
                        } } },
                    }, allocator);
                }
            }
        },
        .pickup_items => |pickup| {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .pickup);
            const level = &current.level.?;
            const entity = getLevelEntity(current, pickup.entity_index);

            // Find the ground stack at the recorded position (one stack
            // per position by invariant; pickup_around pushed exactly
            // one event per in-range stack, so it is present).
            var stack_index: ?usize = null;
            for (level.ground_items, 0..) |ground_item_stack, index| {
                if (ground_item_stack.position.x == pickup.position.x and
                    ground_item_stack.position.y == pickup.position.y)
                {
                    stack_index = index;
                    break;
                }
            }
            if (stack_index == null) @panic("pickup_items: ground stack not found at position");

            // Transfer items into the entity's inventory (first-empty-
            // slot); collect the ones that don't fit as leftovers.
            // Items the PLAYER actually picks up also count toward the
            // mission's converted-materials accumulator (the clone's
            // rate numerator) - valued at salvage value regardless of
            // what the player later does with the item. Leftover items
            // that don't fit stay on the ground and don't count. See
            // DESIGN → Clones (clone system).
            const stack = level.ground_items[stack_index.?];
            var leftover_items: std.ArrayList(types.Item) = .empty;
            const is_player = pickup.entity_index == 0;
            const mission_ptr: ?*types.Mission =
                if (is_player) (if (current.mission) |*m| m else null) else null;
            for (stack.items) |item| {
                var placed = false;
                for (&entity.inventory.slots) |*slot| {
                    if (slot.* == null) {
                        slot.* = item;
                        placed = true;
                        break;
                    }
                }
                if (placed) {
                    if (mission_ptr) |mission| {
                        const value = functions.computeSalvageValue(item, history.salvage_definitions);
                        mission.converted_materials_collected.add(value);
                    }
                } else {
                    leftover_items.append(allocator, item) catch
                        @panic("failed to append leftover item");
                }
            }

            // Rebuild ground_items: drop this stack if fully picked up,
            // or replace it with the leftovers in place.
            var rebuilt: std.ArrayList(types.GroundItems) = .empty;
            for (level.ground_items, 0..) |ground_item_stack, index| {
                if (index == stack_index.?) {
                    if (leftover_items.items.len > 0) {
                        rebuilt.append(allocator, .{
                            .position = ground_item_stack.position,
                            .items = leftover_items.toOwnedSlice(allocator) catch
                                @panic("failed to allocate leftover items"),
                        }) catch @panic("failed to append leftover stack");
                    }
                } else {
                    rebuilt.append(allocator, ground_item_stack) catch
                        @panic("failed to copy ground stack");
                }
            }
            level.ground_items = rebuilt.toOwnedSlice(allocator) catch
                @panic("failed to allocate ground items");
        },
        .stun => |stun| {
            const attacker = getLevelEntity(current, stun.attacker_index);
            const defender = getLevelEntity(current, stun.defender_index);

            if (attacker.current_health == 0) return;
            if (defender.current_health == 0) return;

            // Hostile-effect activation - see the attack arm.
            if (!defender.is_active) activateEntity(history, defender, stun.defender_index);

            const effective_duration = defender.getEffectiveIncomingStunDuration(stun.stun_duration);

            if (effective_duration > 0) {
                // MAX, not sum: a new stun takes the longer of current vs
                // incoming, never stacks - a player facing multiple stunning
                // enemies can't be mega-stunlocked. Stun skills' AI reflects
                // this (they rate/prefer unstunned targets). See DESIGN →
                // Architecture (the stun rule).
                defender.stun_duration = @max(defender.stun_duration, effective_duration);

                if (!history.replaying) history.session.queueSound(history.backing_allocator, .stun);

                for (attacker.active_effects) |active_effect| {
                    const definition = lookups.getEffectDefinition(active_effect.effect_id);
                    if (definition.onOutgoingStun(stun.attacker_index, current.*, allocator)) |effect_events| {
                        pushEvents(current, effect_events, allocator);
                    }
                }
                for (defender.active_effects) |active_effect| {
                    const definition = lookups.getEffectDefinition(active_effect.effect_id);
                    if (definition.onIncomingStun(stun.defender_index, current.*, allocator)) |effect_events| {
                        pushEvents(current, effect_events, allocator);
                    }
                }
            }
        },
        .knockback => |knockback| {
            const level = &current.level.?;
            const attacker = getLevelEntity(current, knockback.attacker_index);
            const defender = getLevelEntity(current, knockback.defender_index);

            if (attacker.current_health == 0) return;
            if (defender.current_health == 0) return;

            // Hostile-effect activation - see the attack arm.
            if (!defender.is_active) activateEntity(history, defender, knockback.defender_index);

            if (!history.replaying) history.session.queueSound(history.backing_allocator, .knockback);

            // Trigger on_outgoing_knockback / on_incoming_knockback
            for (attacker.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onOutgoingKnockback(knockback.attacker_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }
            for (defender.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onIncomingKnockback(knockback.defender_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }

            // Normalize direction: attacker -> defender, each axis to -1/0/+1
            const raw_delta_x = defender.position.x - attacker.position.x;
            const raw_delta_y = defender.position.y - attacker.position.y;
            const direction_x: i32 = if (raw_delta_x > 0) 1 else if (raw_delta_x < 0) @as(i32, -1) else 0;
            const direction_y: i32 = if (raw_delta_y > 0) 1 else if (raw_delta_y < 0) @as(i32, -1) else 0;

            // Collision substrate (the mover - the defender - never blocks
            // its own forced move; see functions.buildCollisionSets).
            var sets = functions.buildCollisionSets(
                level.*,
                knockback.defender_index,
                null,
                allocator,
            ) catch @panic("failed to build collision sets");
            const tile_set = &sets.tile_set;
            const occupied = &sets.occupied;

            // Step incrementally in the knockback direction
            var destination = defender.position;
            var collided = false;
            for (0..knockback.distance) |_| {
                const next_position = Vector2{
                    .x = destination.x + direction_x,
                    .y = destination.y + direction_y,
                };

                if (!tile_set.contains(next_position) or occupied.contains(next_position)) {
                    collided = true;
                    break;
                }

                destination = next_position;
            }

            // Collision event FIRST, forced move SECOND - LIFO pops the
            // move first, so the slide lands BEFORE the crunch resolves
            // (with the collision → damage wait, the impact visuals land
            // after the push is visible). Pushing the move first would
            // apply collision damage + anims while the defender is still at
            // its origin tile.
            if (collided) {
                pushEvents(current, &.{
                    .{ .sub_level_event = .{ .collision = .{
                        .attacker_index = knockback.attacker_index,
                        .defender_index = knockback.defender_index,
                        .damage = knockback.knockback_damage,
                    } } },
                }, allocator);
            }

            // Move entity if position changed
            if (destination.x != defender.position.x or destination.y != defender.position.y) {
                pushEvents(current, &.{
                    .{ .level_event = .{ .move_entity = .{
                        .entity_index = knockback.defender_index,
                        .destination = destination,
                        .is_forced = true,
                    } } },
                }, allocator);
            }
        },
        .collision => |collision| {
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .collision);
            const attacker = getLevelEntity(current, collision.attacker_index);
            const defender = getLevelEntity(current, collision.defender_index);

            if (defender.current_health == 0) return;

            // Hostile-effect activation - a knockback shoved into an
            // uninvolved inactive entity aggros it. See the attack arm.
            if (!defender.is_active) activateEntity(history, defender, collision.defender_index);

            // Trigger on_outgoing_collision / on_incoming_collision
            for (attacker.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onOutgoingCollision(collision.attacker_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }
            for (defender.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onIncomingCollision(collision.defender_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }

            // Apply collision damage. The skill site already
            // applied the attacker's outgoing modifiers (same as
            // `attack`); the handler applies only the defender's
            // incoming modifiers. Collision does NOT go through
            // damage intercepts - deliberate counterplay around
            // Reflect. See DESIGN → Architecture.
            const incoming_damage = defender.getEffectiveIncomingDamage(collision.damage);

            // Hand the resolved amount to the shared damage apply arm
            // (attack/collision converge there; the `triggers_effects`
            // default is true - collision damage callbacks were ungated),
            // with an intra-hit pacing wait between resolve and apply (see
            // DESIGN → Architecture → Skill pacing). LIFO: the wait sits
            // LAST so it pops FIRST - the damage lands once it elapses.
            pushEvents(current, &.{
                .{ .sub_level_event = .{ .damage = .{
                    .attacker_index = collision.attacker_index,
                    .defender_index = collision.defender_index,
                    .amount = incoming_damage,
                } } },
                .{ .meta_event = .{ .accelerating_wait = .{} } },
            }, allocator);
        },
        .damage => |damage_event| {
            // Shared damage apply pipeline for `attack` and `collision` (the
            // resolution differences stay at their pusher arms - see the
            // event's doc comment in events.zig).
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .damage);
            const attacker = getLevelEntity(current, damage_event.attacker_index);
            const defender = getLevelEntity(current, damage_event.defender_index);

            if (defender.current_health == 0) return;

            // Damage number always shows (even 0) so a connecting
            // hit is observable - a fully-absorbed attack no longer
            // looks like a whiff. The hit flash stays gated on > 0
            // (a flash reads as "damage was dealt"). See DESIGN →
            // Animation.
            if (!history.replaying) {
                history.session.queueAnim(history.backing_allocator, .{
                    .event_index = history.current_event_index - 1,
                    .kind = .{ .damage_number = .{
                        .entity_index = damage_event.defender_index,
                        .value = damage_event.amount,
                        .direction = damageNumberDirection(attacker.position, defender.position),
                    } },
                    .duration_us = number_anim_duration_microseconds,
                });
            }

            if (damage_event.amount > 0) {
                // Apply damage
                if (damage_event.amount >= defender.current_health) {
                    defender.current_health = 0;
                } else {
                    defender.current_health -= damage_event.amount;
                }

                // Mission stats: damage dealt (player is attacker)
                // / taken (player is defender). See DESIGN → Clones
                // (clone system).
                if (playerMissionPtr(current)) |mission| {
                    if (damage_event.attacker_index == 0) mission.damage_dealt += damage_event.amount;
                    if (damage_event.defender_index == 0) mission.damage_taken += damage_event.amount;
                }

                // One-shot hit flash on the defender (gated
                // `!replaying`, same shape as the skill-icon anim).
                // Only when damage is actually dealt. See DESIGN →
                // Animation.
                if (!history.replaying) {
                    history.session.queueAnim(history.backing_allocator, .{
                        .event_index = history.current_event_index - 1,
                        .kind = .{ .hit_flash = .{
                            .entity_index = damage_event.defender_index,
                        } },
                        .duration_us = 250_000,
                    });
                }

                // Trigger on_outgoing_damage / on_incoming_damage effect callbacks
                if (damage_event.triggers_effects) {
                    for (attacker.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onOutgoingDamage(damage_event.attacker_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }
                    for (defender.active_effects) |active_effect| {
                        const definition = lookups.getEffectDefinition(active_effect.effect_id);
                        if (definition.onIncomingDamage(damage_event.defender_index, current.*, allocator)) |effect_events| {
                            pushEvents(current, effect_events, allocator);
                        }
                    }
                }

                // Push death if defender health reached 0
                if (defender.current_health == 0) {
                    pushEvents(current, &.{
                        .{ .sub_level_event = .{ .death = .{
                            .entity_index = damage_event.defender_index,
                        } } },
                    }, allocator);
                }

                // Lifesteal: heal the attacker for the damage dealt
                // (composes the generic heal primitive).
                if (damage_event.heals_attacker) {
                    pushEvents(current, &.{
                        .{ .sub_level_event = .{ .heal = .{
                            .entity_index = damage_event.attacker_index,
                            .amount = damage_event.amount,
                        } } },
                    }, allocator);
                }
            }
        },
        .attack => |attack| {
            const attacker = getLevelEntity(current, attack.attacker_index);
            const defender = getLevelEntity(current, attack.defender_index);

            if (attacker.current_health == 0) return;
            if (defender.current_health == 0) return;

            // Being the defender of a hostile effect activates an inactive
            // entity - a hit from beyond aggro_range aggros, even when the
            // damage is fully mitigated (targeted counts). See DESIGN →
            // Architecture (the aggro paragraph).
            if (!defender.is_active) activateEntity(history, defender, attack.defender_index);

            // Trigger on_attack effect callbacks for attacker
            if (attack.triggers_effects) {
                for (attacker.active_effects) |active_effect| {
                    const definition = lookups.getEffectDefinition(active_effect.effect_id);
                    if (definition.onAttack(attack.attacker_index, current.*, allocator)) |effect_events| {
                        pushEvents(current, effect_events, allocator);
                    }
                }
            }

            // Damage pipeline: transform stage. The defender's effects
            // can change the outgoing damage before defense (Reflect
            // zeroes it and reflects it back). Gated on triggers_effects
            // so a reflected attack (triggers_effects=false) is not
            // re-intercepted - no reflect-vs-reflect loops.
            var effective_outgoing = attack.outgoing_damage;
            if (attack.triggers_effects) {
                for (defender.active_effects) |active_effect| {
                    const definition = lookups.getEffectDefinition(active_effect.effect_id);
                    const interception = definition.interceptIncomingDamage(
                        attack.defender_index,
                        attack.attacker_index,
                        effective_outgoing,
                        current.*,
                        allocator,
                    );
                    effective_outgoing = interception.damage;
                    pushEvents(current, interception.events, allocator);
                }
            }

            // Calculate effective incoming damage
            const incoming_damage = defender.getEffectiveIncomingDamage(effective_outgoing);

            // Hand the resolved amount to the shared damage apply arm, with
            // an intra-hit pacing wait between resolve and apply (see DESIGN →
            // Architecture → Skill pacing). LIFO: the wait sits LAST in the
            // array so it pops FIRST - the damage lands once it elapses.
            pushEvents(current, &.{
                .{ .sub_level_event = .{ .damage = .{
                    .attacker_index = attack.attacker_index,
                    .defender_index = attack.defender_index,
                    .amount = incoming_damage,
                    .triggers_effects = attack.triggers_effects,
                    .heals_attacker = attack.heals_attacker,
                } } },
                .{ .meta_event = .{ .accelerating_wait = .{} } },
            }, allocator);
        },
        .create_effect => |create| {
            const caster = getLevelEntity(current, create.caster_index);
            const receiver = getLevelEntity(current, create.receiver_index);

            if (receiver.current_health == 0) return;

            // Calculate effective duration from receiver's incoming modifier
            const effective_duration = receiver.getEffectiveIncomingSkillDuration(create.duration);
            if (effective_duration == 0) return;

            // Trigger on_outgoing_effect on caster's existing effects
            for (caster.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onOutgoingEffect(create.caster_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }

            // Trigger on_incoming_effect on receiver's existing effects (before adding new one)
            for (receiver.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onIncomingEffect(create.receiver_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }

            // Check if receiver already has this effect - extend duration if so
            const effect_definition = lookups.getEffectDefinition(create.effect_id);
            var found_existing = false;
            for (@constCast(receiver.active_effects)) |*active_effect| {
                if (active_effect.effect_id == create.effect_id) {
                    active_effect.duration += effective_duration;
                    found_existing = true;
                    break;
                }
            }

            if (!found_existing) {
                // Add as a new effect
                var updated_effects: std.ArrayList(types.Effect) = .empty;
                updated_effects.appendSlice(allocator, receiver.active_effects) catch
                    @panic("failed to copy active effects");
                updated_effects.append(allocator, .{
                    .effect_id = create.effect_id,
                    .duration = effective_duration,
                    .additive_effect_modifiers = effect_definition.additive_effect_modifiers,
                }) catch @panic("failed to append new effect");
                receiver.active_effects = updated_effects.toOwnedSlice(allocator) catch
                    @panic("failed to allocate updated effects");
            }

            // Trigger on_effect_creation for the effect
            if (effect_definition.onEffectCreation(create.receiver_index, current.*, allocator)) |creation_events| {
                pushEvents(current, creation_events, allocator);
            }
        },
        .death => |death| {
            const level = &current.level.?;
            const entity = level.entities[death.entity_index];

            // Player death: play the defeat sound (side effect,
            // gated !replaying) and freeze-frame - clear the
            // remaining event stack so the rest of the enemy turn
            // doesn't play out. The mission_fail overlay is derived
            // from player health in view(), so no flag or event is
            // needed. Undo reconstructs to the pre-enemy-turn idle
            // point; the death state is derivable from health == 0.
            // See DESIGN → Architecture.
            if (death.entity_index == 0) {
                if (!history.replaying) history.session.queueSound(history.backing_allocator, .defeat);
                current.event_stack = &.{};
                return;
            }

            // Enemy death sound (the player keeps the dedicated defeat
            // sting above). See DESIGN → Audio.
            if (!history.replaying) history.session.queueSound(history.backing_allocator, .death);

            // Trigger on_opponent_death on all alive, active entities from opposing teams
            for (level.entities, 0..) |other_entity, other_index| {
                if (other_index == death.entity_index) continue;
                if (other_entity.current_health == 0) continue;
                if (!other_entity.is_active) continue;
                if (other_entity.team == entity.team) continue;
                for (other_entity.active_effects) |active_effect| {
                    const definition = lookups.getEffectDefinition(active_effect.effect_id);
                    if (definition.onOpponentDeath(@intCast(other_index), current.*, allocator)) |effect_events| {
                        pushEvents(current, effect_events, allocator);
                    }
                }
            }

            // Drop items for non-player entities
            if (death.entity_index != 0) {
                var dropped_items: std.ArrayList(types.Item) = .empty;

                // Drop equipped gear
                if (entity.main_hand_weapon) |weapon|
                    dropped_items.append(allocator, .{ .weapon = weapon }) catch @panic("failed to append dropped item");
                if (entity.off_hand_weapon) |weapon|
                    dropped_items.append(allocator, .{ .weapon = weapon }) catch @panic("failed to append dropped item");
                if (entity.amulet) |amulet|
                    dropped_items.append(allocator, .{ .amulet = amulet }) catch @panic("failed to append dropped item");
                if (entity.coat) |coat|
                    dropped_items.append(allocator, .{ .coat = coat }) catch @panic("failed to append dropped item");
                if (entity.gloves) |gloves|
                    dropped_items.append(allocator, .{ .gloves = gloves }) catch @panic("failed to append dropped item");
                if (entity.pants) |pants|
                    dropped_items.append(allocator, .{ .pants = pants }) catch @panic("failed to append dropped item");
                if (entity.boots) |boots|
                    dropped_items.append(allocator, .{ .boots = boots }) catch @panic("failed to append dropped item");

                // Drop inventory contents
                for (&entity.inventory.slots) |slot| {
                    if (slot) |item| {
                        dropped_items.append(allocator, item) catch @panic("failed to append dropped item");
                    }
                }

                // Drop skill tomes for each equipped utility skill
                for (&entity.equipped_utility_skills) |slot| {
                    if (slot) |skill_id| {
                        dropped_items.append(allocator, .{ .skill_tome = .{
                            .skill = skill_id,
                        } }) catch @panic("failed to append dropped skill tome");
                    }
                }

                if (dropped_items.items.len > 0) {
                    const items_slice = dropped_items.toOwnedSlice(allocator) catch
                        @panic("failed to allocate dropped items");

                    // Find existing GroundItems at this position, or create new
                    var found_ground_items = false;
                    var updated_ground_items: std.ArrayList(types.GroundItems) = .empty;
                    for (level.ground_items) |ground_item_stack| {
                        if (ground_item_stack.position.x == entity.position.x and
                            ground_item_stack.position.y == entity.position.y)
                        {
                            // Merge into existing stack
                            var merged: std.ArrayList(types.Item) = .empty;
                            merged.appendSlice(allocator, ground_item_stack.items) catch
                                @panic("failed to merge ground items");
                            merged.appendSlice(allocator, items_slice) catch
                                @panic("failed to merge ground items");
                            updated_ground_items.append(allocator, .{
                                .position = entity.position,
                                .items = merged.toOwnedSlice(allocator) catch
                                    @panic("failed to allocate merged items"),
                            }) catch @panic("failed to append ground items");
                            found_ground_items = true;
                        } else {
                            updated_ground_items.append(allocator, ground_item_stack) catch
                                @panic("failed to append ground items");
                        }
                    }

                    if (!found_ground_items) {
                        updated_ground_items.append(allocator, .{
                            .position = entity.position,
                            .items = items_slice,
                        }) catch @panic("failed to append new ground items");
                    }

                    level.ground_items = updated_ground_items.toOwnedSlice(allocator) catch
                        @panic("failed to allocate ground items");
                }
            }

            // A death changes the alive-enemy count; if the player
            // is standing on the exit, re-check the win condition so
            // killing the last enemy ends the level without an extra
            // move. See DESIGN → Architecture.
            pushEvents(current, &.{
                .{ .sub_level_event = .{ .check_level_end = .{} } },
            }, allocator);
        },
        .end_effect => |end| {
            const entity = getLevelEntity(current, end.entity_index);

            // Trigger on_effect_end callback
            const definition = lookups.getEffectDefinition(end.effect_id);
            if (definition.onEffectEnd(end.entity_index, current.*, allocator)) |effect_events| {
                pushEvents(current, effect_events, allocator);
            }

            // Remove the effect from active_effects
            var remaining: std.ArrayList(types.Effect) = .empty;
            for (entity.active_effects) |active_effect| {
                if (active_effect.effect_id != end.effect_id) {
                    remaining.append(allocator, active_effect) catch
                        @panic("failed to append remaining effect");
                }
            }
            entity.active_effects = remaining.toOwnedSlice(allocator) catch
                @panic("failed to allocate remaining effects");
        },
        .retreat => |retreat| {
            const level = &current.level.?;
            const entity = getLevelEntity(current, retreat.entity_index);

            if (entity.current_health == 0) return;

            if (!history.replaying) history.session.queueSound(history.backing_allocator, .retreat);

            // Trigger on_retreat effect callbacks
            for (entity.active_effects) |active_effect| {
                const definition = lookups.getEffectDefinition(active_effect.effect_id);
                if (definition.onRetreat(retreat.entity_index, current.*, allocator)) |effect_events| {
                    pushEvents(current, effect_events, allocator);
                }
            }

            // Direction: away from target_position (opposite of knockback direction)
            const raw_delta_x = entity.position.x - retreat.target_position.x;
            const raw_delta_y = entity.position.y - retreat.target_position.y;
            const direction_x: i32 = if (raw_delta_x > 0) 1 else if (raw_delta_x < 0) @as(i32, -1) else 0;
            const direction_y: i32 = if (raw_delta_y > 0) 1 else if (raw_delta_y < 0) @as(i32, -1) else 0;

            // Collision substrate (the mover never blocks its own forced
            // move; see functions.buildCollisionSets).
            var sets = functions.buildCollisionSets(
                level.*,
                retreat.entity_index,
                null,
                allocator,
            ) catch @panic("failed to build collision sets");
            const tile_set = &sets.tile_set;
            const occupied = &sets.occupied;

            // Step incrementally away from target
            var destination = entity.position;
            for (0..retreat.distance) |_| {
                const next_position = Vector2{
                    .x = destination.x + direction_x,
                    .y = destination.y + direction_y,
                };

                if (!tile_set.contains(next_position) or occupied.contains(next_position)) {
                    break;
                }

                destination = next_position;
            }

            // Move entity if position changed
            if (destination.x != entity.position.x or destination.y != entity.position.y) {
                pushEvents(current, &.{
                    .{ .level_event = .{ .move_entity = .{
                        .entity_index = retreat.entity_index,
                        .destination = destination,
                        .is_forced = true,
                    } } },
                }, allocator);
            }
        },
        .heal => |heal_event| {
            const entity = getLevelEntity(current, heal_event.entity_index);
            if (entity.current_health == 0) return; // no reviving via heal
            const capacity = entity.getEffectiveMaxHealth() - entity.current_health;
            const applied = @min(heal_event.amount, capacity);
            entity.current_health += applied;
            // Heal number (`+value`) floating up-right from the
            // entity's top-left bbox corner. Gated `!replaying`.
            // Only when heal is actually applied (a full-health heal
            // shows nothing). See AGENTS Animation.
            if (!history.replaying and applied > 0) {
                history.session.queueSound(history.backing_allocator, .heal);
                history.session.queueAnim(history.backing_allocator, .{
                    .event_index = history.current_event_index - 1,
                    .kind = .{ .heal_number = .{
                        .entity_index = heal_event.entity_index,
                        .value = applied,
                    } },
                    .duration_us = number_anim_duration_microseconds,
                });
            }
        },
        .change_momentum => |change| {
            const entity = getLevelEntity(current, change.entity_index);
            if (entity.current_health == 0) return;
            entity.momentum = functions.applySignedDelta(entity.momentum, change.delta);
        },
        .change_cooldown => |change| {
            const entity = getLevelEntity(current, change.entity_index);
            if (entity.current_health == 0) return;
            const current_cooldown = entity.skill_cooldowns.get(change.skill_id);
            entity.skill_cooldowns.set(change.skill_id, functions.applySignedDelta(current_cooldown, change.delta));
        },
        .swap_positions => |swap| {
            const entity_a = getLevelEntity(current, swap.entity_a_index);
            const entity_b = getLevelEntity(current, swap.entity_b_index);
            if (entity_a.current_health == 0 or entity_b.current_health == 0) return;
            // Hostile-effect activation - the swap TARGET (entity_b) is
            // targeted even though no damage lands. See the attack arm.
            if (!entity_b.is_active) activateEntity(history, entity_b, swap.entity_b_index);
            // Capture both positions before either move, then reuse
            // `move_entity` for both legs so all post-move events
            // (sound, momentum, pickup, aggro, level-end) fire
            // uniformly. `is_forced`: a swap is a magical teleport,
            // not a voluntary walk. LIFO: entity_b moves first (to
            // pos_a), then entity_a (to pos_b). See DESIGN →
            // Architecture.
            const pos_a = entity_a.position;
            const pos_b = entity_b.position;
            pushEvents(current, &.{
                .{ .level_event = .{ .move_entity = .{
                    .entity_index = swap.entity_a_index,
                    .destination = pos_b,
                    .is_forced = true,
                } } },
                .{ .level_event = .{ .move_entity = .{
                    .entity_index = swap.entity_b_index,
                    .destination = pos_a,
                    .is_forced = true,
                } } },
            }, allocator);
        },
        .aggro_in_radius => |aggro| {
            const level = &current.level.?;
            const entity = level.entities[aggro.entity_index];
            const radius: i32 = @intCast(aggro.radius);
            for (level.entities, 0..) |*other_entity, other_index| {
                if (other_index == aggro.entity_index) continue;
                if (other_entity.current_health == 0) continue;
                // No team filter: Howl rallies same-team entities
                // (a wolf howling to aggro its pack), and aggroing
                // opposing entities (including the player) is
                // harmless - `is_active` on the player is ignored by
                // the loops that skip entity 0.
                if (functions.chebyshevDistance(entity.position, other_entity.position) <= radius) {
                    activateEntity(history, @constCast(other_entity), @intCast(other_index));
                }
            }
        },
        .reset_weapon_cooldowns => |reset| {
            // Resolve the entity's weapon skills (slots 1-3) - needs
            // weapon_type_definitions from history, hence a handler and
            // not the skill's useSkill. Emit a change_cooldown per
            // skill on cooldown (composes the cooldown primitive).
            const entity = getLevelEntity(current, reset.entity_index);
            if (entity.current_health == 0) return;
            var slot: u8 = 1;
            while (slot <= 3) : (slot += 1) {
                const skill_id = entity.skillInSlot(slot, history.weapon_type_definitions) orelse continue;
                const current_cooldown = entity.skill_cooldowns.get(skill_id);
                if (current_cooldown == 0) continue;
                pushEvents(current, &.{
                    .{ .sub_level_event = .{ .change_cooldown = .{
                        .entity_index = reset.entity_index,
                        .skill_id = skill_id,
                        .delta = -@as(i32, @intCast(current_cooldown)),
                    } } },
                }, allocator);
            }
        },
        .adrenaline_surge => |surge| {
            // Reset the defender's on-bar cooldowns (Entity.onBarSkillIds -
            // both weapons' full sets + utility), then the attacker strikes
            // once per reset. Enumeration needs weapon_type_definitions
            // (the reset_weapon_cooldowns precedent); the count drives the
            // attack fan, so reset and attacks resolve in the same place.
            // The skill's aiOptions computes the same count for its rating.
            const attacker = getLevelEntity(current, surge.attacker_index);
            const defender = getLevelEntity(current, surge.defender_index);
            if (attacker.current_health == 0) return;
            if (defender.current_health == 0) return;

            var reset_events: std.ArrayList(Event) = .empty;
            var reset_count: u32 = 0;
            for (defender.onBarSkillIds(history.weapon_type_definitions)) |maybe_skill_id| {
                const skill_id = maybe_skill_id orelse continue;
                const current_cooldown = defender.skill_cooldowns.get(skill_id);
                if (current_cooldown == 0) continue;
                reset_events.append(allocator, .{ .sub_level_event = .{ .change_cooldown = .{
                    .entity_index = surge.defender_index,
                    .skill_id = skill_id,
                    .delta = -@as(i32, @intCast(current_cooldown)),
                } } }) catch @panic("failed to append adrenaline reset");
                reset_count += 1;
            }
            if (reset_count == 0) return;

            // LIFO: later pushes drain first, so the RESETS go on the stack
            // LAST - they run before the attacks, landing even when the
            // attacks kill the defender (change_cooldown no-ops on a dead
            // entity, so the reverse order would lose the resets).
            const damage = attacker.getEffectiveSpellDamage();
            var attack_events: std.ArrayList(Event) = .empty;
            for (0..reset_count) |_| {
                attack_events.append(allocator, .{ .sub_level_event = .{ .attack = .{
                    .attacker_index = surge.attacker_index,
                    .defender_index = surge.defender_index,
                    .outgoing_damage = damage,
                } } }) catch @panic("failed to append adrenaline attack");
            }
            pushEvents(current, attack_events.items, allocator);
            pushEvents(current, reset_events.items, allocator);
        },
    }
}
