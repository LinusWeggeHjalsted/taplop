const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const deep_copy = @import("deep_copy.zig");
const input = @import("input.zig");
const ui = @import("ui.zig");

const deepCopy = deep_copy.deepCopy;

const Event = events.Event;
const UiState = ui.UiState;
const Settings = types.Settings;
const WeaponType = types.WeaponType;
const WeaponTypeDefinition = types.WeaponTypeDefinition;

const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;
const PlayerData = types.PlayerData;
const Camera = types.Camera;
const ColorThemeDefinitions = types.ColorThemeDefinitions;
const SalvageDefinitions = types.SalvageDefinitions;
const Editor = types.Editor;
const ReplayViewer = types.ReplayViewer;
const Campaign = types.Campaign;
const Mission = types.Mission;
const Level = types.Level;
const Hub = types.Hub;

pub const Screen = enum {
    main_menu,
    hub,
    level,
    editor,
    replay_viewer,

    const Scope = struct {
        campaign: bool = false,
        mission: bool = false,
        level: bool = false,
        hub: bool = false,
        editor: bool = false,
        replay_viewer: bool = false,
    };

    /// Which optional GameState fields are in scope for this screen.
    pub fn scope(self: Screen) Scope {
        return switch (self) {
            .main_menu => .{},
            .hub => .{ .campaign = true, .hub = true },
            .level => .{ .campaign = true, .mission = true, .level = true },
            .editor => .{ .editor = true, .level = true },
            .replay_viewer => .{ .replay_viewer = true },
        };
    }
};

// Transient real-time pacing state, set when a `wait` event is processed and
// drained by update() as frames elapse. Purely cosmetic: never affects
// gameplay outcomes and is nulled out during replay reconstruction. Stored in
// microseconds to avoid truncation drift when accumulating small frame deltas.
pub const WaitState = struct {
    remaining_microseconds: u64,
};

// Transient view/input state. Deliberately NOT part of the undoable GameState:
// it never affects gameplay outcomes and is not reconstructed by event replay.
// Lives on GameStateHistory alongside settings. UI panels are reset on screen
// transition by the live loop (see gameLoop), not by an event.
pub const SessionState = struct {
    input_state: input.InputState = .{},
    ui_state: UiState = .{},
};

pub const GameState = struct {
    screen: Screen,
    event_stack: []const Event,
    // Non-null while turn flow is paused (see WaitState).
    waiting: ?WaitState = null,
    player_data: PlayerData,
    camera: ?Camera,
    editor: ?Editor,
    replay_viewer: ?ReplayViewer,
    campaign: ?Campaign,
    mission: ?Mission,
    level: ?Level,
    hub: ?Hub,

    /// Transition to a new screen, clearing any data that was in scope
    /// for the old screen but is not in scope for the new one.
    /// Also clears the event stack to prevent dangling events from the
    /// previous screen (e.g. level events lingering after exit to menu).
    pub fn transitionScreen(self: *GameState, new_screen: Screen) void {
        self.event_stack = &.{};

        const old_scope = self.screen.scope();
        const new_scope = new_screen.scope();

        if (old_scope.campaign and !new_scope.campaign) self.campaign = null;
        if (old_scope.mission and !new_scope.mission) self.mission = null;
        if (old_scope.level and !new_scope.level) self.level = null;
        if (old_scope.hub and !new_scope.hub) self.hub = null;
        if (old_scope.editor and !new_scope.editor) self.editor = null;
        if (old_scope.replay_viewer and !new_scope.replay_viewer) self.replay_viewer = null;

        self.screen = new_screen;
    }
};

// A saved GameState at a known event index, with its own arena owning all
// referenced memory. Used for both snapshots (frequent, ring buffer) and
// checkpoints (at major transitions, ring buffer).
pub const SavedState = struct {
    state: GameState,
    event_index: u32, // position in the full event history
    arena: std.heap.ArenaAllocator, // owns all memory referenced by this state
};

pub const snapshot_count = 8; // snapshots saved in each direction from current position
pub const checkpoint_count = 8; // checkpoints kept in ring buffer

pub const GameStateHistory = struct {
    // Player preferences — not part of game state, not affected by undo/redo.
    settings: Settings,

    // Transient view/input state — not part of game state, not affected by
    // undo/redo. See SessionState.
    session: SessionState = .{},

    // Static game data loaded once at startup.
    weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
    color_theme_definitions: ColorThemeDefinitions,
    salvage_definitions: SalvageDefinitions,

    // File I/O handles for standalone mode. On web, file loading goes
    // through JS — these are not used.
    directory: std.Io.Dir,
    io: std.Io,

    // The initial game state at launch — ultimate fallback for replay.
    initial_state: GameState,
    initial_arena: std.heap.ArenaAllocator, // owns all memory referenced by initial_state

    // Complete event history since game launch.
    // Any game state can be reconstructed by replaying events from initial_state.
    event_history: std.ArrayList(Event),

    // Ring buffer of checkpoints at major game transitions (entering a level/hub).
    // Replay starts from the nearest checkpoint before the target, keeping
    // replay chains short even late in a session.
    checkpoints: [checkpoint_count]?SavedState,
    checkpoint_ring_index: u32, // next slot to write in ring buffer

    // Ring buffer of snapshots around the current position, for fast undo/redo
    // without replaying. Only taken when the event stack is empty
    // (i.e. waiting for player input).
    snapshots: [snapshot_count * 2]?SavedState,
    snapshot_ring_index: u32, // next slot to write in ring buffer

    // Event indices where the event stack was empty (waiting for player input).
    // These are the only points that undo/redo will stop at.
    idle_points: std.ArrayList(u32),

    // Which idle point we're currently at. Points into idle_points.
    current_idle_index: u32,

    // Current position in the event history.
    current_event_index: u32,

    // The base allocator (gpa) backing every arena. Stored so the history
    // methods don't have to thread it through on every call.
    backing_allocator: std.mem.Allocator,

    // Durable arena for the append-only session log (event_history + idle_points
    // backing, plus deep-copied event payloads). Event payload slices are the
    // replay source of truth, so they must outlive current_arena resets — hence
    // a separate arena from current_state's. Grows unbounded with the session
    // (accepted; see TODO Memory / Budget); never reset.
    history_arena: std.heap.ArenaAllocator,

    // The live game state — what update() works on and view() renders.
    current_state: GameState,
    current_arena: std.heap.ArenaAllocator, // owns all memory referenced by current_state

    // True while replaying events to reconstruct a past state (undo/redo).
    // Event handlers must run pure state transforms unconditionally, but gate
    // observable side effects (file writes, downloads, audio, dialogs) on
    // !replaying so scrubbing history doesn't re-fire them. Reconstruction
    // reads (level/hub/save config) still run — the rebuilt state depends on
    // them. See processEvent handlers.
    replaying: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        initial_state: GameState,
        settings: Settings,
        weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
        color_theme_definitions: ColorThemeDefinitions,
        salvage_definitions: SalvageDefinitions,
        directory: std.Io.Dir,
        io: std.Io,
    ) GameStateHistory {
        return .{
            .settings = settings,
            .weapon_type_definitions = weapon_type_definitions,
            .color_theme_definitions = color_theme_definitions,
            .salvage_definitions = salvage_definitions,
            .directory = directory,
            .io = io,
            .backing_allocator = allocator,
            .history_arena = std.heap.ArenaAllocator.init(allocator),
            .initial_state = initial_state,
            .initial_arena = std.heap.ArenaAllocator.init(allocator),
            .event_history = .{ .items = &.{}, .capacity = 0 },
            .checkpoints = .{null} ** checkpoint_count,
            .checkpoint_ring_index = 0,
            .snapshots = .{null} ** (snapshot_count * 2),
            .snapshot_ring_index = 0,
            .idle_points = .{ .items = &.{}, .capacity = 0 },
            .current_idle_index = 0,
            .current_event_index = 0,
            .current_state = initial_state,
            .current_arena = std.heap.ArenaAllocator.init(allocator),
            .replaying = false,
        };
    }

    /// Record a live (non-replay) event into the history log. If the player has
    /// undone and is now taking a new action, the previously-recorded events
    /// ahead of the current position are a stale branch: discard them before
    /// appending, so the new action continues a fresh timeline from here.
    /// Only call while !replaying (replay must not create events).
    pub fn recordEvent(
        self: *GameStateHistory,
        event: Event,
    ) void {
        if (self.current_event_index < self.event_history.items.len) {
            self.discardFutureTimeline();
        }
        // Deep-copy into the durable history arena: the event's payload slices
        // may point into current_arena, which is reset on the next
        // reconstruction; the recorded copy must stand on its own.
        const arena = self.history_arena.allocator();
        const durable_event = deepCopy(Event, event, arena);
        self.event_history.append(arena, durable_event) catch @panic("failed to append event");
    }

    /// Drop the recorded timeline ahead of the current position — the stale
    /// future left behind when the player undoes and then acts. Trims the event
    /// log and idle points to the current position and frees any snapshots /
    /// checkpoints that captured the abandoned branch (those at a later event
    /// index; positions at or before the branch point are shared history).
    fn discardFutureTimeline(self: *GameStateHistory) void {
        self.event_history.shrinkRetainingCapacity(self.current_event_index);

        // current_event_index is an idle point (new events only start from
        // one), so idle_points[current_idle_index] == current_event_index;
        // keep up to and including it, drop the rest.
        self.idle_points.shrinkRetainingCapacity(self.current_idle_index + 1);

        for (&self.snapshots) |*slot| {
            if (slot.*) |*saved| {
                if (saved.event_index > self.current_event_index) {
                    saved.arena.deinit();
                    slot.* = null;
                }
            }
        }
        for (&self.checkpoints) |*slot| {
            if (slot.*) |*saved| {
                if (saved.event_index > self.current_event_index) {
                    saved.arena.deinit();
                    slot.* = null;
                }
            }
        }
    }

    /// Save a snapshot at the current position (call when event stack is empty).
    /// Also records this as an idle point for undo/redo.
    pub fn takeSnapshot(
        self: *GameStateHistory,
    ) void {
        // Record this event index as an undo/redo stop (durable session log).
        self.idle_points.append(self.history_arena.allocator(), self.current_event_index) catch @panic("failed to append idle point");
        self.current_idle_index = @intCast(self.idle_points.items.len - 1);

        // Find the ring buffer slot to use
        const slot = self.snapshot_ring_index % (snapshot_count * 2);

        // Free the old snapshot's arena if one exists in this slot
        if (self.snapshots[slot]) |*old| {
            old.arena.deinit();
        }

        // Create a new arena and copy the current state into it
        self.snapshots[slot] = .{
            .state = undefined,
            .event_index = self.current_event_index,
            .arena = std.heap.ArenaAllocator.init(self.backing_allocator),
        };
        self.snapshots[slot].?.state = deepCopy(GameState, self.current_state, self.snapshots[slot].?.arena.allocator());

        self.snapshot_ring_index += 1;
    }

    /// Save a checkpoint at the current position (call on major game transitions).
    pub fn setCheckpoint(
        self: *GameStateHistory,
    ) void {
        const slot = self.checkpoint_ring_index % checkpoint_count;

        // Free the old checkpoint's arena if one exists in this slot
        if (self.checkpoints[slot]) |*old| {
            old.arena.deinit();
        }

        // Create a new arena and copy the current state into it
        self.checkpoints[slot] = .{
            .state = undefined,
            .event_index = self.current_event_index,
            .arena = std.heap.ArenaAllocator.init(self.backing_allocator),
        };
        self.checkpoints[slot].?.state = deepCopy(GameState, self.current_state, self.checkpoints[slot].?.arena.allocator());

        self.checkpoint_ring_index += 1;
    }

    /// Compact current_state into a fresh arena, reclaiming the per-turn churn
    /// (abandoned event-stack reallocations, rebuilt slices, exited levels/hubs)
    /// that accumulated in current_arena since the last reset. Call at idle
    /// points (stack empty) during live play only — replay manages current_arena
    /// itself. Without this, current_arena grows unbounded across a long forward
    /// session (it is otherwise only reset on undo/redo reconstruction).
    pub fn compactCurrentArena(self: *GameStateHistory) void {
        var fresh = std.heap.ArenaAllocator.init(self.backing_allocator);
        const rebuilt = deepCopy(GameState, self.current_state, fresh.allocator());
        self.current_arena.deinit();
        self.current_arena = fresh;
        self.current_state = rebuilt;
    }

    /// Find a saved state in a buffer that exactly matches the given event index.
    fn findExact(
        buffer: []const ?SavedState,
        target_event_index: u32,
    ) ?*const SavedState {
        for (buffer) |*slot| {
            if (slot.*) |*saved| {
                if (saved.event_index == target_event_index) {
                    return saved;
                }
            }
        }
        return null;
    }

    /// Find the nearest saved state at or before the target event index.
    /// Searches both checkpoints and snapshots, returns whichever is closest.
    fn findNearestBefore(
        self: *const GameStateHistory,
        target_event_index: u32,
    ) ?*const SavedState {
        var best: ?*const SavedState = null;

        const buffers = [_][]const ?SavedState{
            &self.checkpoints,
            &self.snapshots,
        };

        for (buffers) |buffer| {
            for (buffer) |*slot| {
                if (slot.*) |*saved| {
                    if (saved.event_index <= target_event_index) {
                        if (best) |best_saved| {
                            if (saved.event_index > best_saved.event_index) {
                                best = saved;
                            }
                        } else {
                            best = saved;
                        }
                    }
                }
            }
        }

        return best;
    }

    /// Replay events up to target_event_index, starting from the best available
    /// restore point (snapshot, checkpoint, or initial state).
    fn replayTo(
        self: *GameStateHistory,
        target_event_index: u32,
        apply_event: *const fn (*GameStateHistory) void,
    ) void {
        // Find the best starting point
        if (self.findNearestBefore(target_event_index)) |saved| {
            self.current_arena.deinit();
            self.current_arena = std.heap.ArenaAllocator.init(self.backing_allocator);
            self.current_state = deepCopy(GameState, saved.state, self.current_arena.allocator());
            self.current_event_index = saved.event_index;
        } else {
            // Fall back to initial state
            self.current_arena.deinit();
            self.current_arena = std.heap.ArenaAllocator.init(self.backing_allocator);
            self.current_state = deepCopy(GameState, self.initial_state, self.current_arena.allocator());
            self.current_event_index = 0;
        }

        // Replay events from starting point up to the target. Handlers gate
        // observable side effects on !replaying (see the replaying field).
        self.replaying = true;
        defer self.replaying = false;
        while (self.current_event_index < target_event_index) {
            const event = self.event_history.items[self.current_event_index];
            self.current_state.event_stack = &.{event};
            apply_event(self);
        }

        // Waits are live-play pacing only. Replay streams events straight
        // through processEvent, which would leave `waiting` set by the last
        // wait event; clear it so the reconstructed idle state isn't stalled.
        self.current_state.waiting = null;
    }

    /// Restore from a saved state, or replay if no exact match exists.
    fn restoreTo(
        self: *GameStateHistory,
        target_event_index: u32,
        apply_event: *const fn (*GameStateHistory) void,
    ) void {
        // Try exact match in snapshots first, then checkpoints
        const exact = findExact(&self.snapshots, target_event_index) orelse
            findExact(&self.checkpoints, target_event_index);

        if (exact) |saved| {
            // Fast path: restore directly
            self.current_arena.deinit();
            self.current_arena = std.heap.ArenaAllocator.init(self.backing_allocator);
            self.current_state = deepCopy(GameState, saved.state, self.current_arena.allocator());
            self.current_event_index = saved.event_index;
        } else {
            // Slow path: replay from nearest restore point
            self.replayTo(target_event_index, apply_event);
        }
    }

    /// Undo to the previous idle point.
    /// Returns true if undo was performed, false if already at the earliest point.
    pub fn undo(
        self: *GameStateHistory,
        apply_event: *const fn (*GameStateHistory) void,
    ) bool {
        if (self.current_idle_index == 0) return false;

        self.current_idle_index -= 1;
        const target_event_index = self.idle_points.items[self.current_idle_index];
        self.restoreTo(target_event_index, apply_event);
        return true;
    }

    /// Redo to the next idle point.
    /// Returns true if redo was performed, false if already at the latest point.
    pub fn redo(
        self: *GameStateHistory,
        apply_event: *const fn (*GameStateHistory) void,
    ) bool {
        if (self.current_idle_index >= self.idle_points.items.len - 1) return false;

        self.current_idle_index += 1;
        const target_event_index = self.idle_points.items[self.current_idle_index];
        self.restoreTo(target_event_index, apply_event);
        return true;
    }

    /// Load a recorded event history (e.g. from a session-log file) and
    /// reconstruct the state at `target_event_index` (pass the event count for
    /// the end). Events are deep-copied into the durable history arena, then
    /// the existing replay machinery rebuilds the state from initial_state.
    ///
    /// Must be called on a freshly-inited history whose initial_state matches
    /// the session's starting state; assumes an empty event_history (no live
    /// timeline to branch from). Intended for session-log replay — the test
    /// harness reconstructs to the end; the replay viewer will later step by
    /// calling this (or restoreTo) at successive targets. idle_points are NOT
    /// populated (they aren't serialized); step boundaries are derived by the
    /// caller, and undo/redo aren't used on a reconstructed log.
    pub fn reconstructFromEventLog(
        self: *GameStateHistory,
        event_log: []const Event,
        target_event_index: u32,
        apply_event: *const fn (*GameStateHistory) void,
    ) void {
        const arena = self.history_arena.allocator();
        for (event_log) |event| {
            const durable_event = deepCopy(Event, event, arena);
            self.event_history.append(arena, durable_event) catch @panic("failed to append event");
        }
        self.replayTo(target_event_index, apply_event);
    }
};

// Build a history with only the timeline-bookkeeping fields populated; the rest
// (settings, definitions, io, current_state) are left undefined because the
// methods under test never read them. Seeds a 5-event forward timeline with
// idle points at indices 2 and 5.
fn historyForTimelineTest(allocator: std.mem.Allocator) GameStateHistory {
    var history: GameStateHistory = undefined;
    history.backing_allocator = allocator;
    history.history_arena = std.heap.ArenaAllocator.init(allocator);
    history.event_history = .{ .items = &.{}, .capacity = 0 };
    history.idle_points = .{ .items = &.{}, .capacity = 0 };
    history.snapshots = .{null} ** (snapshot_count * 2);
    history.checkpoints = .{null} ** checkpoint_count;
    history.snapshot_ring_index = 0;
    history.checkpoint_ring_index = 0;

    // Back the session log with the durable history arena, matching production
    // (recordEvent appends there); the arena's deinit frees both lists.
    const arena = history.history_arena.allocator();
    const dummy_event: Event = .{ .meta_event = .open_main_menu };
    for (0..5) |_| history.event_history.append(arena, dummy_event) catch unreachable;
    history.idle_points.append(arena, 2) catch unreachable;
    history.idle_points.append(arena, 5) catch unreachable;
    return history;
}

test "discardFutureTimeline trims the log, idle points, and stale snapshots" {
    const allocator = std.testing.allocator;
    var history = historyForTimelineTest(allocator);
    defer history.history_arena.deinit();

    // A snapshot ahead of the branch (index 5, stale) and one at the branch
    // point (index 2, shared history).
    history.snapshots[0] = .{ .state = undefined, .event_index = 5, .arena = std.heap.ArenaAllocator.init(allocator) };
    history.snapshots[1] = .{ .state = undefined, .event_index = 2, .arena = std.heap.ArenaAllocator.init(allocator) };
    defer if (history.snapshots[1]) |*saved| saved.arena.deinit();

    // Player has undone to the idle point at index 2.
    history.current_idle_index = 0;
    history.current_event_index = 2;

    history.discardFutureTimeline();

    try std.testing.expectEqual(@as(usize, 2), history.event_history.items.len);
    try std.testing.expectEqual(@as(usize, 1), history.idle_points.items.len);
    try std.testing.expectEqual(@as(u32, 2), history.idle_points.items[0]);
    try std.testing.expect(history.snapshots[0] == null); // stale, freed
    try std.testing.expect(history.snapshots[1] != null); // shared, kept
}

test "recordEvent discards the stale future before appending a new branch" {
    const allocator = std.testing.allocator;
    var history = historyForTimelineTest(allocator);
    defer history.history_arena.deinit();

    // Player has undone to index 2, then takes a new action.
    history.current_idle_index = 0;
    history.current_event_index = 2;
    history.recordEvent(.{ .meta_event = .open_main_menu });

    // Future (indices 2..5) discarded, then the new event appended at 2.
    try std.testing.expectEqual(@as(usize, 3), history.event_history.items.len);
    try std.testing.expectEqual(@as(usize, 1), history.idle_points.items.len);
}

test "recordEvent appends without trimming during normal forward play" {
    const allocator = std.testing.allocator;
    var history = historyForTimelineTest(allocator);
    defer history.history_arena.deinit();

    // At the head of the timeline (index == log length): no branch.
    history.current_idle_index = 1;
    history.current_event_index = 5;
    history.recordEvent(.{ .meta_event = .open_main_menu });

    try std.testing.expectEqual(@as(usize, 6), history.event_history.items.len);
    try std.testing.expectEqual(@as(usize, 2), history.idle_points.items.len);
}
