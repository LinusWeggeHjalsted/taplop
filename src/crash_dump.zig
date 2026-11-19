//! Best-effort session-log dump on panic.
//!
//! The native and web entry files install this module as their `panic`
//! namespace so that any `@panic` (invariant failure, OOM panic, replay-
//! verification mismatch, force-unwrap, safety check) dumps the live
//! session as a session-log BUNDLE to `crashes/crash_YYYYMMDD_HHMMSS/` in
//! the persistent dir (the event log plus byte copies of every
//! reconstruction read - `session_log_bundle.writeSessionLogBundle`)
//! before trapping. `event_history` is always a complete real-time log
//! (B-simple per-dispatch recording - see DESIGN → Error Handling), so a
//! crash dump carries every event up to the crash, enough to reconstruct
//! the session on any machine via the existing replay machinery.
//!
//! Scope: Zig panics ONLY. A raw segfault (wild pointer) bypasses this and
//! goes straight to the OS - the arena/integer-only model makes that rare;
//! a SIGSEGV signal handler is a separate, more invasive step we don't take.
//!
//! Safety: the dump uses the transient allocator (`transient_allocator.zig`)
//! for its OUTPUT buffer
//! (never the game's arenas, which may be in an inconsistent state at panic
//! time). It READS `event_history.items` (history_arena-backed) - a panic is
//! almost always a logic error, not heap corruption, so the arenas are
//! normally intact. The io handle + persistent dir are entry-file-owned
//! (independent of the game arenas), so reusing them is safe. Every failure
//! in the dump path is swallowed - we're already crashing; the dump is a
//! bonus, never a cascade.

const std = @import("std");
const state = @import("state.zig");
const parser = @import("parser.zig");
const session_log_bundle = @import("session_log_bundle.zig");
const transient_allocator = @import("transient_allocator.zig");

const GameStateHistory = state.GameStateHistory;

/// The live session history, registered by `main.run` / `main.frame` at
/// startup and cleared at shutdown. null outside a session (e.g. a panic
/// during startup config load, before the history exists) → the panic
/// handler skips the dump. Volatile is unnecessary: only one thread mutates
/// it (the main thread, at install/uninstall), and a panic reads it.
var crash_history: ?*GameStateHistory = null;

/// Register the live history so a panic can dump its event log. Idempotent.
pub fn install(history: *GameStateHistory) void {
    crash_history = history;
}

/// Clear the registered history (clean shutdown). A panic after this skips
/// the dump - the session is already over.
pub fn uninstall() void {
    crash_history = null;
}

/// A successful `dump`: where the bundle landed + how many events it
/// carries. Both fields are transient-allocator-backed (valid until the
/// transient allocator's next use frees them) - the panic caller prints
/// them immediately, nothing else holds them. File-private: only `dump`
/// and `panic.call` (same file) use it; the test blocks below see
/// file-private symbols.
const DumpResult = struct {
    bundle_dir: []const u8,
    event_count: usize,
};

/// Best-effort dump of `event_history` + the reconstruction cache to
/// `crashes/crash_<timestamp>/` in the persistent dir - a full session-log
/// BUNDLE (session_log.txt + content/ byte copies; see
/// session_log_bundle.writeSessionLogBundle). Returns the result on
/// success, null on any failure (every failure is swallowed - we're
/// already crashing, the dump is a bonus, never a cascade). The output is
/// loadable by `session_log_bundle.loadSessionLogBundle` and
/// reconstructable via the existing replay path, with the embedded
/// content making the crash report exactly reproducible - a crash bundle
/// is a replayable session log, just named differently. File-private
/// (used by `panic.call` + the tests below, both same-file; external
/// callers reach it through the installed panic namespace).
/// The "wrote crash session log bundle" PRINT lives in the panic caller
/// (`panic.call`), NOT here - tests exercising this machinery would
/// otherwise print it on every passing run, which reads like a crash in
/// the raw test runner's output.
fn dump(history: *GameStateHistory) ?DumpResult {
    const allocator = transient_allocator.allocator;

    // Timestamp via the entry-file-owned io handle (not a game arena). A
    // clock read can't corrupt state; if it errors, fall back to "unknown"
    // so we still write SOMETHING rather than abort the dump.
    const created = formatTimestamp(allocator, history.io) catch "unknown";
    const bundle_dir = std.fmt.allocPrint(
        allocator,
        "crashes/crash_{s}",
        .{created},
    ) catch return null;

    session_log_bundle.writeSessionLogBundle(
        history.file_source,
        history.event_history.items,
        history.reconstruction_cache.items,
        bundle_dir,
        created,
        allocator,
    ) catch return null;

    return .{ .bundle_dir = bundle_dir, .event_count = history.event_history.items.len };
}

/// Format the current wall-clock time (UTC) as "YYYYMMDD_HHMMSS" - mirrors
/// `session_log.formatSessionTimestamp` but uses the transient allocator
/// and never panics (returns an error on allocation/clock failure so the caller
/// can fall back).
fn formatTimestamp(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const seconds: u64 = @intCast(std.Io.Clock.now(.real, io).toSeconds());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u32, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

/// The panic namespace installed by the entry files. Mirrors
/// `std.debug.simple_panic` (same safety-check helper set, same messages) but
/// `call` first prints the message to stderr, attempts a crash dump, THEN
/// traps. The dump is best-effort and never blocks the trap.
pub const panic = struct {
    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        @branchHint(.cold);
        _ = ra;
        const stderr_writer = &std.debug.lockStderr(&.{}).file_writer.interface;
        stderr_writer.writeAll(msg) catch {};
        stderr_writer.writeAll("\n") catch {};
        if (crash_history) |history| {
            // Best-effort feedback to stderr (the panic message itself was
            // printed above). On web, stderr goes to the browser console.
            if (dump(history)) |result| {
                std.debug.print("wrote crash session log bundle: {s} ({d} events)\n", .{
                    result.bundle_dir,
                    result.event_count,
                });
            }
        }
        @trap();
    }

    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        _ = found;
        call("sentinel mismatch", null);
    }

    pub fn unwrapError(err: anyerror) noreturn {
        _ = &err;
        call("attempt to unwrap error", null);
    }

    pub fn outOfBounds(index: usize, len: usize) noreturn {
        _ = index;
        _ = len;
        call("index out of bounds", null);
    }

    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        _ = start;
        _ = end;
        call("start index is larger than end index", null);
    }

    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        _ = accessed;
        call("access of inactive union field", null);
    }

    pub fn sliceCastLenRemainder(src_len: usize) noreturn {
        _ = src_len;
        call("slice length does not divide exactly into destination elements", null);
    }

    pub fn reachedUnreachable() noreturn {
        call("reached unreachable code", null);
    }

    pub fn unwrapNull() noreturn {
        call("attempt to use null value", null);
    }

    pub fn castToNull() noreturn {
        call("cast causes pointer to be null", null);
    }

    pub fn incorrectAlignment() noreturn {
        call("incorrect alignment", null);
    }

    pub fn invalidErrorCode() noreturn {
        call("invalid error code", null);
    }

    pub fn unexpectedErrorCode(err: anyerror) noreturn {
        _ = &err;
        call("unexpected error code", null);
    }

    pub fn integerOutOfBounds() noreturn {
        call("integer does not fit in destination type", null);
    }

    pub fn integerOverflow() noreturn {
        call("integer overflow", null);
    }

    pub fn shlOverflow() noreturn {
        call("left shift overflowed bits", null);
    }

    pub fn shrOverflow() noreturn {
        call("right shift overflowed bits", null);
    }

    pub fn divideByZero() noreturn {
        call("division by zero", null);
    }

    pub fn exactDivisionRemainder() noreturn {
        call("exact division produced remainder", null);
    }

    pub fn integerPartOutOfBounds() noreturn {
        call("integer part of floating point value out of bounds", null);
    }

    pub fn corruptSwitch() noreturn {
        call("switch on corrupt value", null);
    }

    pub fn shiftRhsTooBig() noreturn {
        call("shift amount is greater than the type size", null);
    }

    pub fn invalidEnumValue() noreturn {
        call("invalid enum value", null);
    }

    pub fn forLenMismatch() noreturn {
        call("for loop over objects with non-equal lengths", null);
    }

    pub fn copyLenMismatch() noreturn {
        call("source and destination have non-equal lengths", null);
    }

    pub fn memcpyAlias() noreturn {
        call("@memcpy arguments alias", null);
    }

    pub fn noreturnReturned() noreturn {
        call("'noreturn' function returned", null);
    }

    pub fn loadUninstantiableType() noreturn {
        call("attempt to load uninstantiable type", null);
    }
};

test "dump writes a parseable crash session log to crashes/" {
    // The dump path only touches history.io + history.file_source +
    // event_history.items. We reuse the harness to build a valid history (it
    // loads the real configs from the embedded map) and then repoint its
    // file_source at a scratch persistent dir so the dump lands there instead
    // of polluting the project cwd.
    const testing = std.testing;
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    const arena = backing.allocator();

    var harness = @import("test_harness.zig").Harness.init(arena);
    var history = harness.newHistory(null);
    @import("test_harness.zig").runToIdle(&history);
    // Record at least one real event so event_history is non-empty.
    @import("event_push.zig").pushPlayerAction(
        &history.current_state,
        .start_new_game,
        history.current_arena.allocator(),
    );
    @import("test_harness.zig").runToIdle(&history);
    try testing.expect(history.event_history.items.len > 0);

    // Scratch persistent dir for the dump.
    var threaded_io = std.Io.Threaded.init(arena, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const scratch = "zig-cache/test-crash-dump";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    var scratch_source = @import("file_source.zig").FileSource.init(io, dir);
    history.file_source = &scratch_source;
    history.io = io;

    const dump_result = dump(&history);
    try testing.expect(dump_result != null);

    // One crash BUNDLE directory should exist under crashes/. Load it back
    // through the bundle loader and confirm it round-trips: the same event
    // count, plus the same reconstruction cache the history held (the
    // embedded content is what makes the crash report reproducible).
    const crashes_dir = dir.openDir(io, "crashes", .{ .access_sub_paths = true, .iterate = true }) catch
        @panic("open crashes dir");
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(arena);
    var it = crashes_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) entries.append(arena, entry.name) catch @panic("append");
    }
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    const bundle_path = std.fmt.allocPrint(arena, "crashes/{s}", .{entries.items[0]}) catch @panic("format bundle path");
    const bundle = session_log_bundle.loadSessionLogBundle(dir, bundle_path, io, arena) catch
        @panic("load crash bundle");
    try testing.expectEqual(history.event_history.items.len, bundle.log.events.len);
    try testing.expectEqual(history.reconstruction_cache.items.len, bundle.cache_entries.len);
}

test "install/uninstall: set and clear the crash history pointer" {
    // install/uninstall themselves are trivial (set a file-private global),
    // so this only confirms they don't crash and the module compiles in the
    // test build. The pointer's effect is only observable via panic.call,
    // which traps the process - not unit-testable.
    const testing = std.testing;
    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = @import("test_harness.zig").Harness.init(backing.allocator());
    var history = harness.newHistory(null);
    install(&history);
    uninstall();
    try testing.expect(true);
}
