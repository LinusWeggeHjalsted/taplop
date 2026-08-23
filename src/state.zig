//! Core game state + the undo/redo/replay timeline. `GameState` is the
//! live, undoable world (current screen, level/hub, entities, player data).
//! `GameStateHistory` wraps it with the append-only `event_history`, the
//! snapshot/checkpoint rings, the reconstruction cache, and `SessionState`
//! (transient view/input state off the undo timeline). All undo/redo/replay
//! flows through `recordEvent`/`replayTo`/`restoreTo`/`reconstructFromEventLog`.
//! See AGENTS → Replay & Side Effects, Architecture (Allocator model).

const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");
const deep_copy = @import("deep_copy.zig");
const input = @import("input.zig");
const ui = @import("ui.zig");
const file_source_mod = @import("file_source.zig");

const FileSource = file_source_mod.FileSource;

const deepCopy = deep_copy.deepCopy;
const deepEqual = deep_copy.deepEqual;
const firstDiffField = deep_copy.firstDiffField;

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
            .level => .{ .campaign = true, .mission = true, .level = true, .editor = true },
            .editor => .{ .editor = true },
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
    /// The event-stack depth when this wait was pushed. While the wait drains,
    /// the live loop processes anytime-interjected events (e.g. swap_weapons)
    /// down to this depth so they're handled immediately instead of sitting
    /// on the stack until the wait elapses. Set by the `wait` handler to the
    /// post-pop stack length (the remaining enemy-turn events). Replay never
    /// reads it — replay streams events straight through and clears
    /// `waiting` after — so it's harmless dead data in any snapshot that
    /// catches a mid-wait state (and idle points are stack-empty, so a wait
    /// implies no snapshot is taken at that moment anyway).
    baseline_stack_depth: usize = 0,
};

// Transient view/input state. Deliberately NOT part of the undoable GameState:
// it never affects gameplay outcomes and is not reconstructed by event replay.
// Lives on GameStateHistory alongside settings. UI panels are reset on screen
// transition by the live loop (see gameLoop), not by an event.
//
// `tile_cursor` is the tile currently under the logical cursor (mouse or
// arrow-key driven). It lives here, not on GameState, because it is transient
// input state: auto_target_at_cursor reads it in the input path
// (handleIdleInput), and the resulting player_use_skill event is what replay
// reproduces — the cursor value at prepare-time is never needed for
// reconstruction. See AGENTS.md "Replay & Side Effects" (SessionState rule).
pub const SessionState = struct {
    input_state: input.InputState = .{},
    ui_state: UiState = .{},
    tile_cursor: ?types.Vector2 = null,
    // Camera pan (right-drag): offset in world pixels added to the player-
    // centered camera, plus the drag anchor. Transient view state — off the
    // undoable GameState, replay-safe by construction (like tile_cursor / the
    // animation clock). Levels/hubs only; cleared on screen transition and on
    // player move (the camera recenters when the player moves). See
    // handleCameraPan in input_handlers.zig.
    camera_pan: ?types.Vector2 = null,
    camera_pan_anchor: ?CameraPanAnchor = null,

    /// Monotonic session-relative animation clock (accumulated microseconds).
    /// Advanced by `frame()` only when the world isn't paused (options menu /
    /// pending error open), so anims freeze during pause and resume cleanly.
    /// Read by `view()` to pick sprite-animation frames (flag banner now;
    /// one-shot anim gating later). NEVER read by event handlers — that would
    /// make a handler impure (its output would depend on wall-clock time),
    /// breaking the replay-verification invariant (handlers are deterministic
    /// functions of (state, event)). See AGENTS → Animation. Off the
    /// undoable GameState → never in snapshots → replay-safe by construction
    /// (replay doesn't render anyway). A fresh session starts at 0 so looping
    /// anims start at frame 0 (raw wall-clock mod would start mid-loop).
    animation_clock: u64 = 0,

    /// Non-pause-gated session-relative monotonic clock (accumulated
    /// microseconds). Unlike `animation_clock` (which freezes during pause),
    /// this advances every frame regardless — used for debounced write
    /// deadlines (settings persistence, future editor autosave) so writes fire
    /// even while the options menu is open. Off the undoable GameState, so
    /// replay-safe by construction. See AGENTS → Input.
    session_clock: u64 = 0,

    /// Pending debounced writes (settings persistence, future editor
    /// autosave). A small fixed array keyed by `PendingWrite.Tag`; each tag
    /// coalesces (a new dirty-mark refreshes the deadline rather than
    /// enqueueing a second write). Fired by `frame()` when the deadline
    /// elapses (gated `!replaying` — but `frame()` is the live path, so the
    /// gate is automatic). See AGENTS → Input.
    pending_writes: [max_pending_writes]?PendingWrite = .{null} ** max_pending_writes,

    // A recoverable load failure (a corrupt/overridden config file, an
    // incompatible session log, etc.) surfaced to the player as a modal
    // popup. Set by the drain loop after a handler returns an error and
    // the state is reverted to the last idle-point snapshot; cleared on
    // dismiss (`Action.dismiss_error`). Off the undoable GameState, so
    // replay-safe by construction (like the other fields here). The message
    // is duped into `history_arena` (durable across frames until process
    // exit); overwriting a prior error leaks the old bytes in the arena —
    // accepted, since errors are rare and small (same unbounded-arena
    // tradeoff as `event_history`). See AGENTS → Error Handling.
    pending_error: ?[]const u8 = null,

    /// Scroll offset (reference-space pixels) within the error popup's body.
    /// Reset to 0 by `setPendingError`. Clamped to `[0, max_scroll]` in
    /// `buildErrorPopup` (the view is the only place that knows `max_scroll`,
    /// since it depends on the wrapped line count). See AGENTS → Error
    /// Handling.
    error_scroll_offset: i32 = 0,

    /// Copy `msg` into the durable history arena and set it as the pending
    /// error. Overwrites (leaks) any prior message. The caller passes
    /// `history_arena.allocator()` so the message outlives `current_arena`
    // compaction (idle points) — a `current_arena`-backed message could be
    // freed while the popup is still displayed.
    pub fn setPendingError(
        self: *SessionState,
        allocator: std.mem.Allocator,
        msg: []const u8,
    ) void {
        self.pending_error = allocator.dupe(u8, msg) catch
            @panic("failed to allocate pending error message");
        self.error_scroll_offset = 0;
    }

    /// Clear the pending error. The bytes live in `history_arena` (never
    /// individually freed), so this just drops the pointer.
    pub fn clearPendingError(self: *SessionState) void {
        self.pending_error = null;
    }

    /// The pending error message, or null when no popup is shown.
    pub fn pendingError(self: *const SessionState) ?[]const u8 {
        return self.pending_error;
    }

    /// Mark a debounced write as dirty. If a write with the same tag is
    /// already pending, refresh its deadline (debounce — a burst of changes
    /// coalesces into one write). If not, enqueue a new one. The max-wait cap
    /// guarantees a write fires within `write_max_wait_microseconds` of the
    /// first dirty mark even under continuous change (a steady stream that
    /// keeps refreshing the debounce would otherwise never fire). `now` is
    /// `session_clock` at the call site. See AGENTS → Input.
    pub fn markWriteDirty(
        self: *SessionState,
        tag: PendingWrite.Tag,
        write_fn: *const fn (*GameStateHistory) void,
        now: u64,
    ) void {
        // Refresh existing entry (debounce).
        for (&self.pending_writes) |*slot| {
            if (slot.*) |*entry| {
                if (entry.tag == tag) {
                    // If the dirty-since age already exceeds max-wait, fire
                    // immediately; otherwise push the deadline out by the
                    // debounce interval from now.
                    if (now - entry.dirty_since >= write_max_wait_microseconds) {
                        entry.deadline = now;
                    } else {
                        entry.deadline = now + write_debounce_microseconds;
                    }
                    return;
                }
            }
        }
        // Enqueue a new entry.
        for (&self.pending_writes) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .tag = tag,
                    .write_fn = write_fn,
                    .dirty_since = now,
                    .deadline = now + write_debounce_microseconds,
                };
                return;
            }
        }
        // No room — the array is too small (a real bug; max_pending_writes
        // should cover all tags). Fire immediately as a fallback.
        write_fn(undefined);
    }

    /// Fire any pending writes whose deadline has elapsed. Called by `frame()`
    /// each tick after advancing `session_clock`. `history` is passed to each
    /// writer fn. Gated `!replaying` — but `frame()` is the live path (replay
    /// goes through `restoreTo`/`replayTo`, not `frame()`), so the gate is
    /// automatic. See AGENTS → Input.
    pub fn fireElapsedWrites(self: *SessionState, history: *GameStateHistory, now: u64) void {
        for (&self.pending_writes) |*slot| {
            if (slot.*) |entry| {
                if (now >= entry.deadline) {
                    entry.write_fn(history);
                    slot.* = null;
                }
            }
        }
    }

    /// Flush all pending writes immediately (shutdown safety net). Called by
    /// the native driver's `defer` and the web `beforeunload` handler so a
    /// quick change-then-quit isn't lost. See AGENTS → Input.
    pub fn flushPendingWrites(self: *SessionState, history: *GameStateHistory) void {
        for (&self.pending_writes) |*slot| {
            if (slot.*) |entry| {
                entry.write_fn(history);
                slot.* = null;
            }
        }
    }
};

/// Maximum number of concurrent pending writes (one per tag). Covers all
/// debounced-write systems; growing past this is a real bug.
const max_pending_writes: usize = 4;

/// Debounced-write cadence. A dirty mark fires after `write_debounce_microseconds`
/// of quiet, or immediately if dirty for longer than `write_max_wait_microseconds`
/// (so a continuous stream of changes can't starve the write forever).
const write_debounce_microseconds: u64 = 1 * std.time.us_per_s;
const write_max_wait_microseconds: u64 = 5 * std.time.us_per_s;

/// One pending debounced write. `write_fn` is called with the `GameStateHistory`
/// when the deadline elapses. See `SessionState.markWriteDirty`.
pub const PendingWrite = struct {
    pub const Tag = enum { settings };

    tag: Tag,
    write_fn: *const fn (*GameStateHistory) void,
    dirty_since: u64,
    deadline: u64,
};

/// The world point grabbed at the start of a camera-pan drag, in float tile
/// units so the cursor tracks it at sub-tile precision (an integer-tile
/// anchor would jump up to half a tile at drag start). See floatWorldPoint
/// in input.zig.
pub const CameraPanAnchor = struct {
    world_x: f32,
    world_y: f32,
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

// One cached file read for a reconstruction-read event, keyed by
// (event_index, path). event_index is the index of the event under
// handling (processEvent increments current_event_index before dispatch,
// so it's current_event_index - 1); path distinguishes the multiple files a
// single handler may read (e.g. start_new_game reads new_player.txt then
// campaign.txt). Entries are appended in monotonic event-index order; within
// an event, in read order. See reconstruction_cache on GameStateHistory.
pub const ReconstructionCacheEntry = struct {
    event_index: u32,
    path: []const u8,
    bytes: []const u8,
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

    // Unified file I/O (read-only content via the embedded map + player
    // overrides; writable artifacts via the persistent dir). Session-resident,
    // like settings — never deep-copied into snapshots, never touched by
    // replay. See AGENTS.md "File System & IO" and file_source.zig.
    file_source: *const FileSource,

    // The general I/O handle (clocks, etc.) — a sibling to `file_source`,
    // NOT nested inside it, because `std.Io` is broader than file reading/
    // writing. Callers that need the clock (e.g. formatSessionTimestamp)
    // read this directly instead of reaching through the file abstraction.
    // A cheap vtable-handle copy of the same `std.Io` that `file_source`
    // also holds.
    io: std.Io,

    // The initial game state at launch — ultimate fallback for replay.
    initial_state: GameState,
    initial_arena: std.heap.ArenaAllocator, // owns all memory referenced by initial_state

    // Complete event history since game launch.
    // Any game state can be reconstructed by replaying events from initial_state.
    event_history: std.ArrayList(Event),

    // Reconstruction cache: the bytes read by each reconstruction-read event
    // (start_level / start_hub / start_mission / load_save), keyed by the
    // event index under handling. Live reads cache their bytes here (in
    // history_arena); replay serves them back from the cache so the bytes a
    // reconstruction-read event applies are a pure function of its position
    // in history — fully deterministic regardless of later file changes
    // (e.g. editor saves overwrite a mission's files mid-session). Entries
    // are appended in monotonic event-index order; trimmed on branch
    // (discardFutureTimeline). See AGENTS.md "Reconstruction cache" and the
    // readReconstructionFile helper below. Not serialized (within-session
    // only).
    reconstruction_cache: std.ArrayList(ReconstructionCacheEntry) = .empty,

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
    // (accepted; see AGENTS → Memory & Budget); never reset.
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

    // Set by a reconstruction-read handler (start_level / start_mission /
    // start_hub / load_save / open_editor) when its config read or parse
    // fails during LIVE play. The drain loop checks this after each
    // processEvent; when set, it reverts to the last idle-point snapshot,
    // trims the failed transaction's recorded events, and surfaces the
    // error via session.pending_error. Distinct from pending_error (which
    // is the user-facing message and can be set advisorially by key
    // validation without triggering a revert). A handler failure during
    // replay panics instead (fail-fast — unexpected; in-session replay has
    // cached bytes). See AGENTS → Error Handling → three contexts.
    load_error: bool = false,

    // True only during cross-session reconstruction (reconstructFromEventLog):
    // the cache starts empty because no live play ever populated it. On a
    // reconstruction-cache miss in this mode, readReconstructionFile falls
    // back to file_source and caches the result (establishing the cache
    // retroactively), instead of panicking. For shipped/immutable content the
    // bytes are identical to the original session; for custom missions they
    // are whatever is on disk now (the cache is not serialized into the
    // session log). In-session undo/redo (replayTo) never sets this and
    // stays panic-on-miss, since live play always cached before replay can
    // reach the same index.
    cross_session_replay: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        initial_state: GameState,
        settings: Settings,
        weapon_type_definitions: *const [weapon_type_count]WeaponTypeDefinition,
        color_theme_definitions: ColorThemeDefinitions,
        salvage_definitions: SalvageDefinitions,
        file_source: *const FileSource,
        io: std.Io,
    ) GameStateHistory {
        return .{
            .settings = settings,
            .weapon_type_definitions = weapon_type_definitions,
            .color_theme_definitions = color_theme_definitions,
            .salvage_definitions = salvage_definitions,
            .file_source = file_source,
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

    /// Read a file for a reconstruction-read event handler (start_level /
    /// start_hub / start_mission / load_save). Live: reads via file_source
    /// and caches the bytes in history_arena, keyed by the event index
    /// under handling. Replay: returns the cached bytes. This makes replay
    /// fully deterministic regardless of later file changes (e.g. editor
    /// saves overwrite a mission's files mid-session) — the bytes a
    /// reconstruction-read event reads are a pure function of its position
    /// in history. Call this INSTEAD of file_source.readFile from any event
    /// handler whose read result becomes part of the reconstructed state.
    ///
    /// Cache-miss during replay is a bug (live always populates before
    /// replay can reach the same index), so we fail fast with a descriptive
    /// panic rather than silently falling back to disk (which would
    /// reintroduce divergence, just quieter). The only legitimate miss is
    /// cross-session log reload, which starts with an empty cache — that
    /// path (reconstructFromEventLog) falls back to file_source and caches
    /// retroactively.
    pub fn readReconstructionFile(
        self: *GameStateHistory,
        path: []const u8,
    ) []const u8 {
        // processEvent increments current_event_index BEFORE dispatching the
        // handler, so the event under handling is at current_event_index - 1.
        // This is identical in live and replay (same increment, same dispatch).
        const event_index = self.current_event_index - 1;
        if (self.replaying) {
            // Binary search by event_index to the first entry for this event,
            // then linear-scan within the event for a matching path (a single
            // handler may read several files; the per-event count is small).
            const items = self.reconstruction_cache.items;
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid].event_index < event_index) lo = mid + 1 else hi = mid;
            }
            var index = lo;
            while (index < items.len and items[index].event_index == event_index) : (index += 1) {
                if (std.mem.eql(u8, items[index].path, path)) return items[index].bytes;
            }
            // Miss. In-session undo/redo (replayTo) never misses — live play
            // cached before replay could reach this index — so that's a bug we
            // fail fast on. Cross-session reconstruction
            // (reconstructFromEventLog) starts with an empty cache; there a
            // miss is expected, so fall back to file_source and cache the
            // result (establishing the cache retroactively). For shipped
            // content the bytes match the original session; for custom
            // missions they're whatever is on disk now — the known cross-
            // session limitation until the cache is serialized (format v2).
            if (!self.cross_session_replay) {
                @panic("reconstruction cache miss: no cached bytes for this event+path (live read did not cache — cross-session reload not yet supported)");
            }
            const arena = self.history_arena.allocator();
            const durable_path = arena.dupe(u8, path) catch @panic("failed to dupe reconstruction cache path");
            const bytes = self.file_source.readFile(arena, path) catch
                @panic("failed to read reconstruction file during cross-session replay");
            self.reconstruction_cache.append(arena, .{
                .event_index = event_index,
                .path = durable_path,
                .bytes = bytes,
            }) catch @panic("failed to append reconstruction cache entry");
            return bytes;
        }
        const arena = self.history_arena.allocator();
        const durable_path = arena.dupe(u8, path) catch @panic("failed to dupe reconstruction cache path");
        const bytes = self.file_source.readFile(arena, path) catch
            @panic("failed to read reconstruction file");
        self.reconstruction_cache.append(arena, .{
            .event_index = event_index,
            .path = durable_path,
            .bytes = bytes,
        }) catch @panic("failed to append reconstruction cache entry");
        return bytes;
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

        // Drop reconstruction-cache entries ahead of the branch. Entries are
        // appended in monotonic event-index order, so find the first with
        // event_index >= current_event_index and shrink to it. The bytes they
        // point at live in history_arena (never individually freed); trimming
        // the list is enough — they're reclaimed only when history_arena is
        // torn down at process exit.
        var cache_keep: usize = self.reconstruction_cache.items.len;
        while (cache_keep > 0 and
            self.reconstruction_cache.items[cache_keep - 1].event_index >= self.current_event_index)
        {
            cache_keep -= 1;
        }
        self.reconstruction_cache.shrinkRetainingCapacity(cache_keep);
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

    /// Record an idle point: the live loop's stack-empty bookkeeping. Bundles
    /// snapshot + arena compaction so the live loop and reconstruction share
    /// one action (detection of the idle boundary differs — the live loop
    /// watches the real stack drain; reconstruction tracks virtual stack
    /// depth over the recorded stream). Call only when the event stack is
    /// empty (live) or the virtual depth has hit 0 (reconstruction).
    pub fn recordIdlePoint(
        self: *GameStateHistory,
    ) void {
        self.takeSnapshot();
        self.compactCurrentArena();
    }

    /// Record an idle point when an event boundary just completed, shared by
    /// `frame()`'s drain loop and idle branch so the detection condition lives
    /// in one place. `events_processed` is the caller's signal that `update()`
    /// actually ran events this tick (drain loop: `had_events`; idle branch:
    /// `current_event_index` advanced). The recording fires only when events
    /// ran, the stack is now empty, and the current position isn't ALREADY an
    /// idle point — that last check excludes undo/redo, which are anytime
    /// actions handled inside `update()` and land on an existing idle point
    /// (recording a duplicate there would corrupt the timeline and make
    /// undo/redo cycle between adjacent states). Reconstruction does not call
    /// this — it records idle points from virtual stack depth in
    /// `replayToWithIdleTracking`.
    pub fn maybeRecordIdlePoint(
        self: *GameStateHistory,
        events_processed: bool,
    ) void {
        if (events_processed and
            self.current_state.event_stack.len == 0 and
            // "Not already an idle point" — excludes undo/redo, which land
            // on an existing idle point (recording a duplicate would corrupt
            // the timeline). Only meaningful when idle_points is non-empty;
            // when empty (the very first idle point at startup) the position
            // can't already be indexed, so record. takeSnapshot appends before
            // indexing, so the empty case never reached this read before.
            (self.idle_points.items.len == 0 or
                self.idle_points.items[self.current_idle_index] != self.current_event_index))
        {
            self.recordIdlePoint();
        }
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

    /// Format an Event's full discriminator ("meta_event.start_level" etc.) into
    /// `buf` for use in replay-mismatch panic messages. The slice is borrowed
    /// from the caller's buffer, valid as long as `buf` lives (i.e. within the
    /// panic-building scope).
    fn eventName(buf: []u8, event: Event) []const u8 {
        return switch (event) {
            .meta_event => |m| std.fmt.bufPrint(buf, "meta_event.{s}", .{@tagName(m)}) catch "meta_event.?",
            .super_event => |m| std.fmt.bufPrint(buf, "super_event.{s}", .{@tagName(m)}) catch "super_event.?",
            .editor_event => |m| std.fmt.bufPrint(buf, "editor_event.{s}", .{@tagName(m)}) catch "editor_event.?",
            .player_event => |m| std.fmt.bufPrint(buf, "player_event.{s}", .{@tagName(m)}) catch "player_event.?",
            .hub_event => |m| std.fmt.bufPrint(buf, "hub_event.{s}", .{@tagName(m)}) catch "hub_event.?",
            .level_event => |m| std.fmt.bufPrint(buf, "level_event.{s}", .{@tagName(m)}) catch "level_event.?",
            .sub_level_event => |m| std.fmt.bufPrint(buf, "sub_level_event.{s}", .{@tagName(m)}) catch "sub_level_event.?",
        .replay_viewer_event => |m| std.fmt.bufPrint(buf, "replay_viewer_event.{s}", .{@tagName(m)}) catch "replay_viewer_event.?",
        };
    }

    /// Verify that the event about to be dispatched (the stack top) matches
    /// the recorded event at `recorded_index`. Called before each
    /// `apply_event` during the natural-stack replay loops (`replayTo` /
    /// `replayToWithIdleTracking`), for handler-pushed children AND seeded
    /// top-level events. For top-level events (just seeded from the
    /// recording) the check is trivially true; for handler-pushed children
    /// it is the real verification — a handler that pushes a different child
    /// than the original session did panics here. A divergence means the
    /// engine's (state, event) → (state', children) transform is not a pure
    /// function of its inputs (a nondeterminism bug), so we fail fast.
    /// Runs for ALL replay origins including cross-session
    /// (`reconstructFromEventLog`); see AGENTS → Determinism & Tiebreaking →
    /// Replay VERIFICATION.
    fn verifyReplayMatch(
        self: *GameStateHistory,
        expected: Event,
        recorded_index: u32,
    ) void {
        const recorded = self.event_history.items[recorded_index];
        if (!deepEqual(Event, expected, recorded)) {
            var exp_buf: [128]u8 = undefined;
            var act_buf: [128]u8 = undefined;
            const exp_name = eventName(&exp_buf, recorded);
            const act_name = eventName(&act_buf, expected);
            const field_hint = firstDiffField(Event, expected, recorded) orelse "";
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf,
                "replay mismatch at recorded event {d}: handler would run {s}, but recorded history has {s} (first differing field: \"{s}\")",
                .{ recorded_index, act_name, exp_name, field_hint },
            ) catch "replay mismatch: handler-pushed event does not match recorded history";
            @panic(msg);
        }
    }

    /// Replay events up to target_event_index, starting from the best available
    /// restore point (snapshot, checkpoint, or initial state). Uses the
    /// natural-stack model (see `replayToWithIdleTracking`): the stack top
    /// before each dispatch must match the recording, verified via
    /// `verifyReplayMatch`. Does not track idle points (undo/redo uses
    /// snapshots for restore points, not derived idle boundaries).
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
            // If the stack drained, seed the next top-level recorded event.
            if (self.current_state.event_stack.len == 0) {
                self.current_state.event_stack =
                    &.{self.event_history.items[self.current_event_index]};
            }

            // Verify: the event about to run (stack top) matches the recording.
            const expected = self.current_state.event_stack[
                self.current_state.event_stack.len - 1];
            self.verifyReplayMatch(expected, self.current_event_index);

            apply_event(self);
        }

        // Waits are live-play pacing only. Replay streams events straight
        // through processEvent, which would leave `waiting` set by the last
        // wait event; clear it so the reconstructed idle state isn't stalled.
        self.current_state.waiting = null;
    }

    /// Replay events up to target_event_index, deriving idle points along the
    /// way so a reconstructed session undoes/steps "as if played live".
    ///
    /// This uses the NATURAL STACK to drive replay + verification (see AGENTS
    /// → Determinism & Tiebreaking → Replay VERIFICATION): instead of force-
    /// feeding each recorded event and discarding handler outputs, we let
    /// `processEvent`'s pop/push machinery run. The event stack IS the DFS
    /// cursor — before each dispatch, the stack top is the event that should
    /// run next, and we verify it equals the recorded event at
    /// `current_event_index`. Handler-pushed children naturally interleave
    /// with their own subtrees in the recorded stream, and the stack tracks
    /// that interleaving for free. When the stack drains, the next recorded
    /// event is a fresh top-level player action — we seed it (top-level
    /// events come from player input, not handlers, so the recording is the
    /// source of truth for them and the check is trivial there).
    ///
    /// Idle points are simply stack-empty moments (depth 0) — the real stack
    /// depth replaces the old virtual-depth bookkeeping. This still relies on
    /// the one-orchestrator-event-per-player-action convention so that each
    /// idle point is a genuine player-action boundary.
    fn replayToWithIdleTracking(
        self: *GameStateHistory,
        target_event_index: u32,
        apply_event: *const fn (*GameStateHistory) void,
    ) void {
        // Reconstruction always starts from the initial state (no snapshots/
        // checkpoints exist on a freshly-inited history). The initial state
        // carries a single seed event on its stack (e.g. open_main_menu), so
        // the first recorded event is that seed.
        self.current_arena.deinit();
        self.current_arena = std.heap.ArenaAllocator.init(self.backing_allocator);
        self.current_state = deepCopy(GameState, self.initial_state, self.current_arena.allocator());
        self.current_event_index = 0;

        self.replaying = true;
        defer self.replaying = false;

        while (self.current_event_index < target_event_index) {
            // If the stack drained, seed the next top-level recorded event.
            // (Top-level events originate from player input, not handlers, so
            // the recording is authoritative for them; the verify below is
            // trivially true right after a seed.)
            if (self.current_state.event_stack.len == 0) {
                self.current_state.event_stack =
                    &.{self.event_history.items[self.current_event_index]};
            }

            // Verify: the event about to run (stack top) matches the recording.
            // For handler-pushed children this is the real check — a handler
            // that pushes a different child than the original session did
            // panics here. For seeded top-level events this is trivially true.
            const expected = self.current_state.event_stack[
                self.current_state.event_stack.len - 1];
            self.verifyReplayMatch(expected, self.current_event_index);

            apply_event(self);

            // Idle point = the stack just drained. (recordIdlePoint snapshots
            // + compacts, mirroring the live gameLoop's idle bookkeeping.)
            if (self.current_state.event_stack.len == 0) {
                self.recordIdlePoint();
            }
        }

        self.current_state.waiting = null;
    }

    /// Restore from a saved state, or replay if no exact match exists.
    pub fn restoreTo(
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

    /// The event index where the current level began: the most recent
    /// `start_level` meta event at or before `current_event_index`. Returns
    /// null if none is in the prefix (e.g. on the main menu or in a hub), so
    /// the combat-log projection knows there is no current-level span to show.
    /// Pure backward scan, O(events since level start).
    pub fn levelStartEventIndex(
        self: *const GameStateHistory,
    ) ?u32 {
        var index: usize = @intCast(self.current_event_index);
        while (index > 0) {
            index -= 1;
            const event = self.event_history.items[index];
            switch (event) {
                .meta_event => |meta| switch (meta) {
                    .start_level => return @intCast(index + 1),
                    else => {},
                },
                else => {},
            }
        }
        return null;
    }

    /// Load a recorded event history (e.g. from a session-log file) and
    /// reconstruct the state at `target_event_index` (pass the event count for
    /// the end). Events are deep-copied into the durable history arena, then
    /// the state is rebuilt from initial_state.
    ///
    /// Idle points are DERIVED during replay via virtual stack depth (see
    /// replayToWithIdleTracking), NOT serialized — so a loaded session undoes/
    /// redoes and steps "as if played live", with matching idle point indices.
    /// This relies on the one-orchestrator-event-per-player-action convention.
    ///
    /// Must be called on a freshly-inited history whose initial_state matches
    /// the session's starting state; assumes an empty event_history (no live
    /// timeline to branch from). Intended for session-log replay — the test
    /// harness reconstructs to the end; the replay viewer steps by calling
    /// this (or restoreTo) at successive targets.
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
        self.cross_session_replay = true;
        defer self.cross_session_replay = false;
        self.replayToWithIdleTracking(target_event_index, apply_event);
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
    history.reconstruction_cache = .empty;
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

test "SessionState pending error: set, read, clear" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var session: SessionState = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), session.pendingError());

    session.setPendingError(arena.allocator(), "failed to parse data/campaigns/act_one.txt");
    try std.testing.expectEqualStrings(
        "failed to parse data/campaigns/act_one.txt",
        session.pendingError().?,
    );

    session.clearPendingError();
    try std.testing.expectEqual(@as(?[]const u8, null), session.pendingError());
}

test "SessionState pending error: overwrite replaces the message" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var session: SessionState = .{};
    session.setPendingError(arena.allocator(), "first error");
    session.setPendingError(arena.allocator(), "second error with more detail");

    try std.testing.expectEqualStrings("second error with more detail", session.pendingError().?);
    session.clearPendingError();
}
