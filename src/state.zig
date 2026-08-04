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

pub const GameState = struct {
    screen: Screen,
    event_stack: []const Event,
    player_data: PlayerData,
    camera: ?Camera,
    input_state: input.InputState,
    ui_state: UiState,
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

        self.ui_state = .{};
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
    // without replaying. Only taken when the event queue is empty
    // (i.e. waiting for player input).
    snapshots: [snapshot_count * 2]?SavedState,
    snapshot_ring_index: u32, // next slot to write in ring buffer

    // Event indices where the event queue was empty (waiting for player input).
    // These are the only points that undo/redo will stop at.
    idle_points: std.ArrayList(u32),

    // Which idle point we're currently at. Points into idle_points.
    current_idle_index: u32,

    // Current position in the event history.
    current_event_index: u32,

    // The live game state — what update() works on and view() renders.
    current_state: GameState,
    current_arena: std.heap.ArenaAllocator, // owns all memory referenced by current_state

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
        };
    }

    /// Save a snapshot at the current position (call when event queue is empty).
    /// Also records this as an idle point for undo/redo.
    pub fn takeSnapshot(
        self: *GameStateHistory,
        allocator: std.mem.Allocator,
    ) void {
        // Record this event index as an undo/redo stop
        self.idle_points.append(allocator, self.current_event_index) catch @panic("failed to append idle point");
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
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        self.snapshots[slot].?.state = deepCopy(GameState, self.current_state, self.snapshots[slot].?.arena.allocator());

        self.snapshot_ring_index += 1;
    }

    /// Save a checkpoint at the current position (call on major game transitions).
    pub fn setCheckpoint(
        self: *GameStateHistory,
        allocator: std.mem.Allocator,
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
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        self.checkpoints[slot].?.state = deepCopy(GameState, self.current_state, self.checkpoints[slot].?.arena.allocator());

        self.checkpoint_ring_index += 1;
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
        allocator: std.mem.Allocator,
        apply_event: *const fn (*GameStateHistory, std.mem.Allocator) void,
    ) void {
        // Find the best starting point
        if (self.findNearestBefore(target_event_index)) |saved| {
            self.current_arena.deinit();
            self.current_arena = std.heap.ArenaAllocator.init(allocator);
            self.current_state = deepCopy(GameState, saved.state, self.current_arena.allocator());
            self.current_event_index = saved.event_index;
        } else {
            // Fall back to initial state
            self.current_arena.deinit();
            self.current_arena = std.heap.ArenaAllocator.init(allocator);
            self.current_state = deepCopy(GameState, self.initial_state, self.current_arena.allocator());
            self.current_event_index = 0;
        }

        // Replay events from starting point up to the target
        while (self.current_event_index < target_event_index) {
            const event = self.event_history.items[self.current_event_index];
            self.current_state.event_stack = &.{event};
            apply_event(self, allocator);
        }
    }

    /// Restore from a saved state, or replay if no exact match exists.
    fn restoreTo(
        self: *GameStateHistory,
        target_event_index: u32,
        allocator: std.mem.Allocator,
        apply_event: *const fn (*GameStateHistory, std.mem.Allocator) void,
    ) void {
        // Try exact match in snapshots first, then checkpoints
        const exact = findExact(&self.snapshots, target_event_index) orelse
            findExact(&self.checkpoints, target_event_index);

        if (exact) |saved| {
            // Fast path: restore directly
            self.current_arena.deinit();
            self.current_arena = std.heap.ArenaAllocator.init(allocator);
            self.current_state = deepCopy(GameState, saved.state, self.current_arena.allocator());
            self.current_event_index = saved.event_index;
        } else {
            // Slow path: replay from nearest restore point
            self.replayTo(target_event_index, allocator, apply_event);
        }
    }

    /// Undo to the previous idle point.
    /// Returns true if undo was performed, false if already at the earliest point.
    pub fn undo(
        self: *GameStateHistory,
        allocator: std.mem.Allocator,
        apply_event: *const fn (*GameStateHistory, std.mem.Allocator) void,
    ) bool {
        if (self.current_idle_index == 0) return false;

        self.current_idle_index -= 1;
        const target_event_index = self.idle_points.items[self.current_idle_index];
        self.restoreTo(target_event_index, allocator, apply_event);
        return true;
    }

    /// Redo to the next idle point.
    /// Returns true if redo was performed, false if already at the latest point.
    pub fn redo(
        self: *GameStateHistory,
        allocator: std.mem.Allocator,
        apply_event: *const fn (*GameStateHistory, std.mem.Allocator) void,
    ) bool {
        if (self.current_idle_index >= self.idle_points.items.len - 1) return false;

        self.current_idle_index += 1;
        const target_event_index = self.idle_points.items[self.current_idle_index];
        self.restoreTo(target_event_index, allocator, apply_event);
        return true;
    }
};
