//! The validation replay artifact — pure machinery over the session-log
//! format: the structural loader (bracket checks + mission metadata keys),
//! turn derivation, medal targets, and the personal-best overwrite
//! decision. The write site (the end_validation success handler) and the
//! consumers (the validation stats screen, the mission browser, the future
//! server-side check) live elsewhere. See DESIGN → Custom Missions &
//! Online Services → Validation replay + Turn counters + author medals.

const std = @import("std");
const events_mod = @import("events.zig");
const parser = @import("parser.zig");
const session_log = @import("session_log.zig");

const Event = events_mod.Event;

/// A loaded validation replay: the final attempt's event slice plus the
/// metadata derivation can't recover from the events (identity + content
/// binding). All memory is `allocator`-owned (the loadEventLog pattern).
pub const ValidationReplay = struct {
    /// Advisory: the build that produced the replay (the standard
    /// game-version caveat — warn on mismatch, not a hard gate).
    game_version: []const u8,
    /// "YYYYMMDD_HHMMSS" verbatim from the file.
    created: []const u8,
    /// The mission's uuid (mission.txt identity), binding the replay to
    /// the mission it validated.
    mission_uuid: []const u8,
    /// SHA-256 over the mission's config files (content_hash.zig) — the
    /// replay certifies THIS content version; a mismatch with the
    /// mission's current hash means "unvalidated".
    content_hash: []const u8,
    events: []const Event,
};

pub const ValidationReplayError = session_log.SessionLogError || error{
    /// The event stream is not a validation bracket: too short, the first
    /// event is not `player_start_validation`, or the last is not
    /// `end_validation{success=true}`.
    NotAValidationReplay,
    /// Metadata lacks `mission_uuid` / `content_hash`.
    MissingValidationMetadata,
};

/// Load + structurally check a validation replay from config sections (the
/// loadEventLog shape: the caller parses the file and owns the sections).
/// The bracket checks encode the file's contract — first event the
/// seedable orchestrator, last event the successful bracket close — so a
/// file that fails here is not a validation replay, whatever its Metadata
/// claims.
pub fn loadValidationReplay(
    sections: []const parser.Section,
    allocator: std.mem.Allocator,
) ValidationReplayError!ValidationReplay {
    const log = try session_log.loadEventLog(sections, allocator);

    if (log.events.len < 2) return error.NotAValidationReplay;
    const first = log.events[0];
    if (first != .player_input_event or first.player_input_event != .player_start_validation) {
        return error.NotAValidationReplay;
    }
    const last = log.events[log.events.len - 1];
    if (last != .meta_event) return error.NotAValidationReplay;
    switch (last.meta_event) {
        .end_validation => |end_validation| if (!end_validation.success) {
            return error.NotAValidationReplay;
        },
        else => return error.NotAValidationReplay,
    }

    const metadata_section = parser.findSection(sections, "Metadata") orelse
        return error.MalformedSessionLog;
    const metadata_pairs = if (metadata_section.entry_groups.len > 0)
        metadata_section.entry_groups[0].pairs
    else
        return error.MalformedSessionLog;
    const mission_uuid = parser.findValue(metadata_pairs, "mission_uuid") orelse
        return error.MissingValidationMetadata;
    const content_hash = parser.findValue(metadata_pairs, "content_hash") orelse
        return error.MissingValidationMetadata;

    return .{
        .game_version = log.game_version,
        .created = log.created,
        .mission_uuid = try allocator.dupe(u8, mission_uuid),
        .content_hash = try allocator.dupe(u8, content_hash),
        .events = log.events,
    };
}

/// The author time: count the player's `turn_start` events (entity_index 0)
/// in the slice. Mirrors the `turn_start` handler's `mission.turns_spent`
/// increment exactly (any mode, while a mission is active) — the two must
/// agree, asserted by the validation crown test against the reconstructed
/// state. Counting turn STARTS (not ends) means the final turn — spent
/// walking onto the level exit, never reaching turn_end — counts. Derived,
/// never stored, so it can't drift from the truth of the replay. See
/// DESIGN → Custom Missions & Online Services → Turn counters
/// + author medals.
pub fn deriveValidationTurns(events: []const Event) u32 {
    var turns: u32 = 0;
    for (events) |event| {
        switch (event) {
            .level_event => |level_event| switch (level_event) {
                .turn_start => |turn_start| {
                    if (turn_start.entity_index == 0) turns += 1;
                },
                else => {},
            },
            else => {},
        }
    }
    return turns;
}

/// Trackmania-style medal targets, derived from the author's turn count:
/// gold = ceil(turns × 1.2), silver = turns × 2, bronze = turns × 5
/// (integer forms — gameplay logic uses no floats). Ceil keeps a target
/// at least 1 turn above the faster tier except at very low author times,
/// where tiers can collide (author_turns = 1 gives gold == silver == 2 —
/// accepted edge case). See DESIGN → Custom Missions & Online Services →
/// Turn counters + author medals.
pub const MedalTargets = struct {
    gold: u32,
    silver: u32,
    bronze: u32,
};

pub fn medalTargets(author_turns: u32) MedalTargets {
    return .{
        .gold = ceilRatio(author_turns * 6, 5),
        .silver = author_turns * 2,
        .bronze = author_turns * 5,
    };
}

/// ceil(numerator / denominator) for positive u32 values.
fn ceilRatio(numerator: u32, denominator: u32) u32 {
    return (numerator + denominator - 1) / denominator;
}

/// What the end_validation success handler does with an existing
/// validation_replay.txt. See DESIGN → Custom Missions & Online Services →
/// Validation replay (personal-best overwrite guard).
pub const ReplayOverwriteDecision = enum {
    /// Write the new replay: no old file (or an unreadable one), old
    /// content the old replay no longer certifies, or a strictly faster
    /// run (a new personal best).
    write,
    /// Keep the old file as the personal best; stash the new bytes on
    /// SessionState and offer a manual overwrite.
    keep_offer_overwrite,
};

/// What is known about an existing validation replay when deciding an
/// overwrite: its derived turns + its content hash.
pub const ExistingReplaySummary = struct {
    turns: u32,
    content_hash: []const u8,
};

pub fn replayOverwriteDecision(
    existing: ?ExistingReplaySummary,
    new_turns: u32,
    new_content_hash: []const u8,
) ReplayOverwriteDecision {
    const old = existing orelse return .write;
    // An old replay whose hash no longer matches certifies an earlier
    // mission version — meaningless for the current content.
    if (!std.mem.eql(u8, old.content_hash, new_content_hash)) return .write;
    // Strictly faster = a new personal best. Ties keep the old file
    // (first-validated wins).
    if (new_turns < old.turns) return .write;
    return .keep_offer_overwrite;
}

// ============================================================
// Tests
// ============================================================

fn expectReplayError(
    sections: []const parser.Section,
    allocator: std.mem.Allocator,
    expected: ValidationReplayError,
) !void {
    try std.testing.expectError(expected, loadValidationReplay(sections, allocator));
}

test "deriveValidationTurns counts only the player's turn starts" {
    const events = [_]Event{
        .{ .player_input_event = .{ .player_start_validation = .{ .mission_path = "" } } },
        .{ .level_event = .{ .turn_start = .{ .entity_index = 0 } } },
        .{ .level_event = .{ .turn_start = .{ .entity_index = 1 } } },
        .{ .level_event = .{ .turn_start = .{ .entity_index = 0 } } },
        .{ .level_event = .{ .turn_start = .{ .entity_index = 2 } } },
        .{ .meta_event = .{ .end_validation = .{ .success = true } } },
    };
    try std.testing.expectEqual(@as(u32, 2), deriveValidationTurns(&events));
    try std.testing.expectEqual(@as(u32, 0), deriveValidationTurns(&[_]Event{}));
}

test "validation replay round trip through the session-log format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const events = [_]Event{
        .{ .player_input_event = .{ .player_start_validation = .{ .mission_path = "" } } },
        .{ .level_event = .{ .turn_start = .{ .entity_index = 0 } } },
        .{ .level_event = .{ .turn_start = .{ .entity_index = 1 } } },
        .{ .level_event = .{ .turn_start = .{ .entity_index = 0 } } },
        .{ .meta_event = .{ .end_validation = .{ .success = true } } },
    };
    const body = try session_log.writeEventLogWithMetadata(
        events[0..],
        "20260101_000000",
        &.{
            .{ .name = "mission_uuid", .value = "01234567-89ab-cdef-0123-456789abcdef" },
            .{ .name = "content_hash", .value = "deadbeef" },
        },
        allocator,
    );
    const sections = try parser.parseConfigFile(body, allocator);
    const replay = try loadValidationReplay(sections, allocator);

    try std.testing.expectEqualStrings(
        "01234567-89ab-cdef-0123-456789abcdef",
        replay.mission_uuid,
    );
    try std.testing.expectEqualStrings("deadbeef", replay.content_hash);
    try std.testing.expectEqualStrings("20260101_000000", replay.created);
    try std.testing.expectEqual(@as(usize, events.len), replay.events.len);
    try std.testing.expectEqualDeep(events[0..], replay.events);
    try std.testing.expectEqual(@as(u32, 2), deriveValidationTurns(replay.events));
}

test "loadValidationReplay rejects non-bracket event streams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const metadata = [_]session_log.MetadataPair{
        .{ .name = "mission_uuid", .value = "uuid" },
        .{ .name = "content_hash", .value = "hash" },
    };

    // Too short — a bracket needs at least the entry orchestrator + the
    // closing event.
    {
        const body = try session_log.writeEventLogWithMetadata(
            &[_]Event{.{ .player_input_event = .{ .player_start_validation = .{ .mission_path = "" } } }},
            "20260101_000000",
            &metadata,
            allocator,
        );
        try expectReplayError(try parser.parseConfigFile(body, allocator), allocator, error.NotAValidationReplay);
    }
    // Wrong first event (not the seedable entry orchestrator).
    {
        const events = [_]Event{
            .{ .level_event = .{ .turn_end = .{ .entity_index = 0 } } },
            .{ .meta_event = .{ .end_validation = .{ .success = true } } },
        };
        const body = try session_log.writeEventLogWithMetadata(
            events[0..],
            "20260101_000000",
            &metadata,
            allocator,
        );
        try expectReplayError(try parser.parseConfigFile(body, allocator), allocator, error.NotAValidationReplay);
    }
    // Wrong last event variant.
    {
        const events = [_]Event{
            .{ .player_input_event = .{ .player_start_validation = .{ .mission_path = "" } } },
            .{ .meta_event = .end_playtest },
        };
        const body = try session_log.writeEventLogWithMetadata(
            events[0..],
            "20260101_000000",
            &metadata,
            allocator,
        );
        try expectReplayError(try parser.parseConfigFile(body, allocator), allocator, error.NotAValidationReplay);
    }
    // A failed validation run is not a replay (only successful runs write
    // one, so a hand-crafted success=false file is rejected).
    {
        const events = [_]Event{
            .{ .player_input_event = .{ .player_start_validation = .{ .mission_path = "" } } },
            .{ .meta_event = .{ .end_validation = .{ .success = false } } },
        };
        const body = try session_log.writeEventLogWithMetadata(
            events[0..],
            "20260101_000000",
            &metadata,
            allocator,
        );
        try expectReplayError(try parser.parseConfigFile(body, allocator), allocator, error.NotAValidationReplay);
    }
}

test "loadValidationReplay requires the mission metadata keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const events = [_]Event{
        .{ .player_input_event = .{ .player_start_validation = .{ .mission_path = "" } } },
        .{ .meta_event = .{ .end_validation = .{ .success = true } } },
    };
    // writeEventLog (no extra pairs) — a plain session log is not a
    // validation replay even with a well-formed bracket.
    const body = try session_log.writeEventLog(events[0..], "20260101_000000", allocator);
    try expectReplayError(
        try parser.parseConfigFile(body, allocator),
        allocator,
        error.MissingValidationMetadata,
    );
}

test "replayOverwriteDecision personal-best guard" {
    const old_hash = "aaaaaaaa";
    const new_hash = "aaaaaaaa";
    const other_hash = "bbbbbbbb";

    // No old file (or an unreadable one — the call site maps load failure
    // to null): always write.
    try std.testing.expectEqual(
        ReplayOverwriteDecision.write,
        replayOverwriteDecision(null, 100, new_hash),
    );

    // Old replay from an earlier mission version (hash mismatch): the old
    // file certifies different content — overwrite regardless of turns.
    try std.testing.expectEqual(
        ReplayOverwriteDecision.write,
        replayOverwriteDecision(.{ .turns = 5, .content_hash = old_hash }, 100, other_hash),
    );

    // Strictly faster: new personal best — write.
    try std.testing.expectEqual(
        ReplayOverwriteDecision.write,
        replayOverwriteDecision(.{ .turns = 10, .content_hash = old_hash }, 9, new_hash),
    );

    // Slower: keep the old best, offer manual overwrite.
    try std.testing.expectEqual(
        ReplayOverwriteDecision.keep_offer_overwrite,
        replayOverwriteDecision(.{ .turns = 10, .content_hash = old_hash }, 11, new_hash),
    );

    // Tie: first-validated wins — keep the old file.
    try std.testing.expectEqual(
        ReplayOverwriteDecision.keep_offer_overwrite,
        replayOverwriteDecision(.{ .turns = 10, .content_hash = old_hash }, 10, new_hash),
    );
}

test "medalTargets derives the settled multipliers with ceil on gold" {
    // The documented collision edge: author_turns = 1 → gold == silver.
    try std.testing.expectEqual(
        MedalTargets{ .gold = 2, .silver = 2, .bronze = 5 },
        medalTargets(1),
    );
    // A non-divisible gold ratio exercises the ceil (5 × 1.2 = 6 exact;
    // 7 × 1.2 = 8.4 → 9).
    try std.testing.expectEqual(
        MedalTargets{ .gold = 6, .silver = 10, .bronze = 25 },
        medalTargets(5),
    );
    try std.testing.expectEqual(
        MedalTargets{ .gold = 9, .silver = 14, .bronze = 35 },
        medalTargets(7),
    );
    try std.testing.expectEqual(
        MedalTargets{ .gold = 12, .silver = 20, .bronze = 50 },
        medalTargets(10),
    );
}
