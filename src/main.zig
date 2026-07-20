const std = @import("std");
const types = @import("types.zig");
const events = @import("events.zig");

const GameState = types.GameState;
const GameEvent = events.GameEvent;
const Vec2 = types.Vec2;

// ============================================================
// Core functions
// ============================================================

// `export` makes these visible to JS when compiled to WASM.
// The build.zig `export_symbol_names` list must include them too.

/// Called once by JS to create the initial game state.
export fn init() GameState {
    _ = {};
}

/// Takes a game state and an event, returns a new game state.
/// This is the functional core — no mutation, no side effects.
export fn update(state: GameState, event: GameEvent) GameState {
    _ = state;
    _ = event;
    _ = {};
}

/// Takes a game state and draws it centered on camera_position.
export fn view(state: GameState, camera_position: Vec2) void {
    _ = camera_position;
    _ = state;
}
