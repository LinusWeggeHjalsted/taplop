//! Session-log serialization/deserialization — the comptime-generic
//! writer + reader over the `Event` union (see DESIGN → Logging & Replay).
//! Separate from the config-file format layer (parser.zig): a session log is
//! `event_history` linearized to config sections, one entry group per event.
//! New events serialize/deserialize with no changes here (comptime reflection
//! over the union). Also owns the session-log timestamp formatter (the
//! `created` stamp shared by the dump, the autosave backup naming, and the
//! validation replay write).

const std = @import("std");
const build_info = @import("build_info");
const events_mod = @import("events.zig");
const parser = @import("parser.zig");

const Event = events_mod.Event;
const Section = parser.Section;
const KeyValuePair = parser.KeyValuePair;
const parseConfigFile = parser.parseConfigFile;
const freeParsedSections = parser.freeParsedSections;
const findSection = parser.findSection;
const findValue = parser.findValue;
const asU32 = parser.asU32;

/// Session-log file format version (hard-gate on load; emitted on write).
/// v2: the session-log BUNDLE adds its `ReconstructionCache` manifest
/// section + `content/` byte copies (session_log_bundle.zig). Bare v2
/// logs without the manifest section are legal (the validation replay is
/// one — the manifest is bundle-required, not format-required).
/// v3: the UI-surface toggle events (`toggle_ui_surface` / `inspect_entity`)
/// — class-1 surface state moved onto GameState (see DESIGN → UI Framework
/// → UI state classification). Old logs re-record rather than migrate
/// (pre-release policy).
pub const session_log_file_format_version: u32 = 3;

// ============================================================
// Session log writer (event history serialization)
// ============================================================
//
// Serializes an event history to the config format so a whole session can be
// dumped (ctrl+L) and later re-read to reconstruct/step through it (see
// DESIGN → Logging & Replay). The event stream alone reproduces a session;
// no player input is logged. The writer is comptime-generic over the `Event`
// union, so new events serialize with no changes here.
//
// Layout:
//   Metadata
//   file_format_version <int>
//   game_version <string>
//   created <YYYYMMDD_HHMMSS>
//
//   EventLog
//
//   event_index <N>
//   event <category> <variant>
//   <field> <value>
//   ...
//
// Each event is one blank-line-separated entry group: a decorative
// `event_index <N>` header line (purely for human readability — the reader
// ignores it, and hand-edited/externally-authored logs may omit it), then the
// `event` pair as the discriminator (outer union tag = category, inner tag =
// variant). Payload fields follow, one per line. Optionals omit their line
// when null. Vector2 / Materials serialize as space-separated ints; slices of
// them (e.g. highlight_tiles) flatten into one space-separated line; enums via
// @tagName.

/// One extra Metadata line for a session-log artifact (`name value`, the
/// same shape as the standard keys). Validation replays carry `mission_uuid`
/// + `content_hash` this way; the reader ignores unknown Metadata keys, so
/// generic session logs are unaffected by the extension.
pub const MetadataPair = struct {
    name: []const u8,
    value: []const u8,
};

/// Format the current wall-clock time (UTC) as "YYYYMMDD_HHMMSS" — the
/// `created` stamp for session-log-shaped artifacts (the ctrl+L dump, the
/// autosave backup file name, the validation replay). A side-effect-adjacent
/// util (reads the clock): called only from live paths, never replay.
pub fn formatSessionTimestamp(
    allocator: std.mem.Allocator,
    io: std.Io,
) []const u8 {
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
    ) catch @panic("failed to format session-log timestamp");
}

/// Serialize an event history (+ a created timestamp) into a session-log file
/// body. `created` is expected as "YYYYMMDD_HHMMSS" but is written verbatim.
pub fn writeEventLog(
    event_history: []const Event,
    created: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    return writeEventLogWithMetadata(event_history, created, &.{}, allocator);
}

/// writeEventLog with extra Metadata pairs appended after the standard
/// keys (same file format — the reader is permissive on unknown Metadata
/// keys). See MetadataPair.
pub fn writeEventLogWithMetadata(
    event_history: []const Event,
    created: []const u8,
    extra_metadata: []const MetadataPair,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;

    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{session_log_file_format_version});
    try buffer.print(allocator, "game_version {s}\n", .{build_info.game_version});
    try buffer.print(allocator, "created {s}\n", .{created});
    for (extra_metadata) |pair| {
        try buffer.print(allocator, "{s} {s}\n", .{ pair.name, pair.value });
    }

    try buffer.appendSlice(allocator, "\nEventLog\n");
    for (event_history, 0..) |event, index| {
        try buffer.appendSlice(allocator, "\n");
        // Decorative index header — purely for human readability when scanning
        // a log. The reader ignores it (not required to parse), so hand-edited
        // or externally-authored logs can omit it entirely.
        try buffer.print(allocator, "event_index {d}\n", .{index});
        try writeEvent(&buffer, allocator, event);
    }

    return try buffer.toOwnedSlice(allocator);
}

/// Write one event as an entry group: the `event <category> <variant>`
/// discriminator followed by one line per payload field.
fn writeEvent(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    event: Event,
) !void {
    switch (event) {
        inline else => |category_payload, category_tag| {
            switch (category_payload) {
                inline else => |variant_payload, variant_tag| {
                    try buffer.print(allocator, "event {s} {s}\n", .{
                        @tagName(category_tag),
                        @tagName(variant_tag),
                    });
                    const Payload = @TypeOf(variant_payload);
                    if (Payload != void) {
                        inline for (@typeInfo(Payload).@"struct".fields) |field| {
                            try writeEventField(
                                buffer,
                                allocator,
                                field.name,
                                @field(variant_payload, field.name),
                            );
                        }
                    }
                },
            }
        },
    }
}

/// Write one payload field as `<name> <value>`. Optionals with a null value
/// omit their line entirely (absence encodes null, matching UtilitySkills).
fn writeEventField(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    value: anytype,
) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => {
            if (value) |inner| try writeEventField(buffer, allocator, name, inner);
        },
        else => {
            // A slice of structs carrying strings (e.g. the decoration
            // def's `layers`): the token stream can't regroup strings with
            // spaces, so each element goes to its OWN indexed lines —
            // see `isStringBearingStructSlice`. The comptime if/else keeps
            // the generic path from instantiating for those slices (its
            // appendEventScalar guard would reject them).
            if (comptime isStringBearingStructSlice(@TypeOf(value))) {
                try writeIndexedSliceField(buffer, allocator, name, value);
            } else {
                try buffer.appendSlice(allocator, name);
                try buffer.appendSlice(allocator, " ");
                try appendEventScalar(buffer, allocator, value);
                try buffer.appendSlice(allocator, "\n");
            }
        },
    }
}

/// Is T a slice of structs that carry a `[]const u8` field (at any depth
/// through nested structs)? Such a slice can't serialize as one
/// space-separated line — a string's spaces would break the reader's
/// positional regrouping (e.g. a layer sprite `custom/My Mission/canopy`).
/// Those fields take the indexed multi-line encoding instead; single
/// nested values flatten to top level (the event-shape convention — see
/// the editor_set_entity_gear / editor_set_item_def comments).
fn isStringBearingStructSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const pointer = info.pointer;
    if (pointer.size != .slice or pointer.child == u8) return false;
    return typeContainsString(pointer.child);
}

/// Does T carry a `[]const u8` anywhere inside (a string field of a
/// struct, recursively through nested structs)?
fn typeContainsString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and pointer.child == u8,
        .@"struct" => |info| blk: {
            for (info.fields) |field| {
                if (typeContainsString(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// Write a string-bearing struct slice as INDEXED lines:
/// `<name>_count N`, then per element one line per field,
/// `<name>_<i>_<field> <value>` — every string on its own line, so
/// spaces round-trip (the reader mirrors this in
/// `parseIndexedSliceField`). Element fields must be one-line values
/// (scalars, enums, strings, structs of scalars like Vector2) — a
/// string-bearing struct/slice NESTED inside an element has no encoding
/// and is a compile error.
fn writeIndexedSliceField(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    value: anytype,
) !void {
    const Element = @typeInfo(@TypeOf(value)).pointer.child;
    inline for (@typeInfo(Element).@"struct".fields) |field| {
        if (comptime !isIndexedSliceFieldLineValue(field.type)) {
            @compileError("indexed slice field element too deep: " ++ @typeName(field.type));
        }
    }
    try buffer.print(allocator, "{s}_count {d}\n", .{ name, value.len });
    for (value, 0..) |element, index| {
        inline for (@typeInfo(Element).@"struct".fields) |field| {
            try buffer.print(allocator, "{s}_{d}_{s} ", .{ name, index, field.name });
            try appendEventScalar(buffer, allocator, @field(element, field.name));
            try buffer.appendSlice(allocator, "\n");
        }
    }
}

/// May an indexed-slice element field serialize as one line? Strings are
/// fine (their line is their own); anything that would need ANOTHER level
/// of regrouping — a string-bearing struct or a non-u8 slice inside the
/// element — is not.
fn isIndexedSliceFieldLineValue(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .pointer) {
        const pointer = info.pointer;
        if (pointer.size == .slice and pointer.child == u8) return true;
        if (pointer.size == .slice) return !typeContainsString(pointer.child);
        return false;
    }
    if (info == .@"struct") return !typeContainsString(T);
    return true;
}

/// Append a single (non-optional) field value: ints as decimals, bools as
/// true/false, enums via @tagName, `[]const u8` verbatim, and structs
/// (Vector2, Materials) as their fields space-separated.
fn appendEventScalar(
    buffer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: anytype,
) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => try buffer.print(allocator, "{d}", .{value}),
        .bool => try buffer.appendSlice(allocator, if (value) "true" else "false"),
        .@"enum" => try buffer.appendSlice(allocator, @tagName(value)),
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("unsupported event field pointer type: " ++ @typeName(T));
            }
            if (pointer.child == u8) {
                // `[]const u8` — a string, verbatim.
                try buffer.appendSlice(allocator, value);
            } else {
                // A slice of scalars/structs (e.g. `[]const Vector2`) flattened
                // as space-separated element reprs. Elements have fixed arity
                // (Vector2 = 2 ints), so decoding regroups; an empty slice
                // writes nothing (an empty value). Structs carrying STRINGS
                // can't take this path (spaces break the regrouping) —
                // `writeEventField` routes them to the indexed encoding, and
                // this guard keeps any future direct caller honest.
                if (comptime typeContainsString(pointer.child)) {
                    @compileError("string-bearing struct slice must use the indexed encoding: " ++ @typeName(T));
                }
                for (value, 0..) |element, index| {
                    if (index != 0) try buffer.appendSlice(allocator, " ");
                    try appendEventScalar(buffer, allocator, element);
                }
            }
        },
        .@"struct" => |info| {
            inline for (info.fields, 0..) |field, index| {
                if (index != 0) try buffer.appendSlice(allocator, " ");
                try appendEventScalar(buffer, allocator, @field(value, field.name));
            }
        },
        .@"union" => |union_info| {
            // A tagged-union field value (e.g. EntityEditTarget, Item):
            // `<tag> <payload-fields...>`. The tag is the first token, then
            // the active payload's fields (recursively flattened). A void
            // payload (e.g. EntityEditTarget.player_def) writes just the tag.
            if (union_info.tag_type) |_| {
                try buffer.appendSlice(allocator, @tagName(value));
                switch (value) {
                    inline else => |payload, tag| {
                        // `tag` is a comptime-known enum value, so indexing
                        // union_info.fields (a comptime tuple) works. A void
                        // payload (e.g. EntityEditTarget.player_def) writes
                        // just the tag — no payload fields appended.
                        const field_info = union_info.fields[@intFromEnum(tag)];
                        if (field_info.type != void) {
                            try buffer.appendSlice(allocator, " ");
                            try appendEventScalar(buffer, allocator, payload);
                        }
                    },
                }
            } else {
                @compileError("unsupported event field: untagged union " ++ @typeName(T));
            }
        },
        .array => {
            // Fixed-size array (e.g. [6]Color in a ColorGradient): flattened
            // as space-separated element reprs, same as a slice. Elements have
            // fixed arity so decoding regroups.
            for (value, 0..) |element, index| {
                if (index != 0) try buffer.appendSlice(allocator, " ");
                try appendEventScalar(buffer, allocator, element);
            }
        },
        else => @compileError("unsupported event field type: " ++ @typeName(T)),
    }
}

// ============================================================
// Session log reader (event history deserialization)
// ============================================================
//
// The comptime-generic inverse of writeEventLog: parses a session-log file
// (already run through parseConfigFile) back into an event history. Reload
// feeds these into the existing replay machinery (NOT the input path) to
// reconstruct/step a session. New events deserialize with no changes here.

pub const SessionLog = struct {
    file_format_version: u32,
    /// The build that produced the log (advisory; caller warns on mismatch).
    game_version: []const u8,
    /// "YYYYMMDD_HHMMSS" (UTC) verbatim from the file.
    created: []const u8,
    events: []const Event,
};

pub const SessionLogError = error{
    /// Metadata / EventLog section missing, or an event entry malformed.
    MalformedSessionLog,
    /// file_format_version is not one this build can read.
    UnsupportedFileFormatVersion,
    OutOfMemory,
};

/// Parse a session log from config sections. All returned memory (events,
/// strings, tile slices) is allocated with `allocator`. `game_version` is
/// returned for the caller to compare against the running build (advisory);
/// file_format_version is a hard gate.
pub fn loadEventLog(
    sections: []const Section,
    allocator: std.mem.Allocator,
) SessionLogError!SessionLog {
    const metadata = findSection(sections, "Metadata") orelse return error.MalformedSessionLog;
    const meta_pairs = if (metadata.entry_groups.len > 0)
        metadata.entry_groups[0].pairs
    else
        return error.MalformedSessionLog;

    const version_string = findValue(meta_pairs, "file_format_version") orelse
        return error.MalformedSessionLog;
    const file_format_version = asU32(version_string) orelse return error.MalformedSessionLog;
    if (file_format_version != session_log_file_format_version) {
        return error.UnsupportedFileFormatVersion;
    }

    const game_version = try allocator.dupe(u8, findValue(meta_pairs, "game_version") orelse "");
    const created = try allocator.dupe(u8, findValue(meta_pairs, "created") orelse "");

    const event_log = findSection(sections, "EventLog") orelse return error.MalformedSessionLog;
    var events: std.ArrayList(Event) = .empty;
    for (event_log.entry_groups) |group| {
        try events.append(allocator, try parseEvent(group.pairs, allocator));
    }

    return .{
        .file_format_version = file_format_version,
        .game_version = game_version,
        .created = created,
        .events = try events.toOwnedSlice(allocator),
    };
}

/// Parse one event entry group: read the `event <category> <variant>`
/// discriminator, then build the payload struct field-by-field by name.
fn parseEvent(
    pairs: []const KeyValuePair,
    allocator: std.mem.Allocator,
) SessionLogError!Event {
    // The event unions have outgrown the default 1000-branch comptime
    // budget — the inline category/variant/payload-field walks evaluate
    // per Payload type.
    @setEvalBranchQuota(10000);
    const discriminator = findValue(pairs, "event") orelse return error.MalformedSessionLog;
    var tokens = std.mem.tokenizeScalar(u8, discriminator, ' ');
    const category = tokens.next() orelse return error.MalformedSessionLog;
    const variant = tokens.next() orelse return error.MalformedSessionLog;

    inline for (@typeInfo(Event).@"union".fields) |category_field| {
        if (std.mem.eql(u8, category, category_field.name)) {
            const Inner = category_field.type;
            inline for (@typeInfo(Inner).@"union".fields) |variant_field| {
                if (std.mem.eql(u8, variant, variant_field.name)) {
                    const Payload = variant_field.type;
                    const inner_value = if (Payload == void)
                        @unionInit(Inner, variant_field.name, {})
                    else inner: {
                        var payload: Payload = undefined;
                        inline for (@typeInfo(Payload).@"struct".fields) |payload_field| {
                            // A string-bearing struct slice reads back its
                            // indexed lines (the writer's mirror — see
                            // writeIndexedSliceField).
                            @field(payload, payload_field.name) =
                                if (comptime isStringBearingStructSlice(payload_field.type))
                                    try parseIndexedSliceField(
                                        payload_field.type,
                                        payload_field.name,
                                        pairs,
                                        allocator,
                                    )
                                else
                                    try parseEventFieldValue(
                                        payload_field.type,
                                        findValue(pairs, payload_field.name),
                                        allocator,
                                    );
                        }
                        break :inner @unionInit(Inner, variant_field.name, payload);
                    };
                    return @unionInit(Event, category_field.name, inner_value);
                }
            }
            return error.MalformedSessionLog; // unknown variant for this category
        }
    }
    return error.MalformedSessionLog; // unknown category
}

/// The reader's mirror of `writeIndexedSliceField`: read `<name>_count N`,
/// then each element's fields from their `<name>_<i>_<field>` lines.
/// Every element field is a required one-line value (the writer's
/// comptime guard guarantees the shape).
fn parseIndexedSliceField(
    comptime Slice: type,
    comptime name: []const u8,
    pairs: []const KeyValuePair,
    allocator: std.mem.Allocator,
) SessionLogError!Slice {
    const Element = @typeInfo(Slice).pointer.child;
    const count_value = findValue(pairs, name ++ "_count") orelse
        return error.MalformedSessionLog;
    const count = std.fmt.parseInt(usize, count_value, 10) catch
        return error.MalformedSessionLog;
    var elements: std.ArrayList(Element) = .empty;
    for (0..count) |index| {
        var element: Element = undefined;
        inline for (@typeInfo(Element).@"struct".fields) |field| {
            const key = std.fmt.allocPrint(
                allocator,
                "{s}_{d}_{s}",
                .{ name, index, field.name },
            ) catch return error.OutOfMemory;
            const value = findValue(pairs, key) orelse
                return error.MalformedSessionLog;
            @field(element, field.name) = try parseEventScalar(field.type, value, allocator);
        }
        try elements.append(allocator, element);
    }
    return try elements.toOwnedSlice(allocator);
}

/// Read one payload field. An absent key is null for optionals (matching the
/// writer's omit-when-null) and malformed for required fields.
fn parseEventFieldValue(
    comptime T: type,
    maybe_value: ?[]const u8,
    allocator: std.mem.Allocator,
) SessionLogError!T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const value = maybe_value orelse return null;
            return try parseEventFieldValue(optional.child, value, allocator);
        },
        else => {
            const value = maybe_value orelse return error.MalformedSessionLog;
            return try parseEventScalar(T, value, allocator);
        },
    }
}

/// Inverse of appendEventScalar: `[]const u8` verbatim (duped), a slice of
/// scalars/structs from all space-separated tokens, everything else from the
/// tokenized value.
fn parseEventScalar(
    comptime T: type,
    value: []const u8,
    allocator: std.mem.Allocator,
) SessionLogError!T {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("unsupported event field pointer type: " ++ @typeName(T));
            }
            if (pointer.child == u8) return try allocator.dupe(u8, value);
            // Slice of fixed-arity elements (e.g. Vector2): consume elements
            // until the tokens run out.
            var elements: std.ArrayList(pointer.child) = .empty;
            var tokens = std.mem.tokenizeScalar(u8, value, ' ');
            while (tokens.peek() != null) {
                try elements.append(allocator, try parseScalarTokens(pointer.child, &tokens, allocator));
            }
            return try elements.toOwnedSlice(allocator);
        },
        else => {
            var tokens = std.mem.tokenizeScalar(u8, value, ' ');
            return parseScalarTokens(T, &tokens, allocator);
        },
    }
}

/// Parse one value from a token stream: ints/bools/enums consume one token,
/// structs (Vector2, Materials) consume one token per (recursively flattened)
/// field — mirroring appendEventScalar's flattening.
fn parseScalarTokens(
    comptime T: type,
    tokens: anytype,
    allocator: std.mem.Allocator,
) SessionLogError!T {
    switch (@typeInfo(T)) {
        .int => {
            const token = tokens.next() orelse return error.MalformedSessionLog;
            return std.fmt.parseInt(T, token, 10) catch error.MalformedSessionLog;
        },
        .bool => {
            const token = tokens.next() orelse return error.MalformedSessionLog;
            if (std.mem.eql(u8, token, "true")) return true;
            if (std.mem.eql(u8, token, "false")) return false;
            return error.MalformedSessionLog;
        },
        .@"enum" => {
            const token = tokens.next() orelse return error.MalformedSessionLog;
            return std.meta.stringToEnum(T, token) orelse error.MalformedSessionLog;
        },
        .pointer => |pointer| {
            // A string field inside a struct/union payload (e.g. Weapon.name,
            // EntityLayer.sprite). Slices of non-u8 aren't handled here —
            // they go through parseEventScalar's token-stream loop at the top
            // level. The string is duped into the caller's allocator so it
            // outlives the input buffer (mirrors parseEventScalar's []const u8).
            if (pointer.size != .slice) {
                @compileError("unsupported event field pointer type: " ++ @typeName(T));
            }
            if (pointer.child != u8) {
                @compileError("parseScalarTokens: slice of non-u8 not supported inside a struct/union — use a top-level field");
            }
            const token = tokens.next() orelse return error.MalformedSessionLog;
            return try allocator.dupe(u8, token);
        },
        .@"struct" => |info| {
            var result: T = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = try parseScalarTokens(field.type, tokens, allocator);
            }
            return result;
        },
        .@"union" => |union_info| {
            // A tagged-union field value: `<tag> <payload-fields...>`. The
            // tag is the first token; for a void payload (e.g.
            // EntityEditTarget.player_def) the tag alone suffices.
            if (union_info.tag_type) |_| {
                const tag_token = tokens.next() orelse return error.MalformedSessionLog;
                inline for (union_info.fields) |field| {
                    if (std.mem.eql(u8, tag_token, field.name)) {
                        if (field.type == void) {
                            return @unionInit(T, field.name, {});
                        } else {
                            const payload = try parseScalarTokens(field.type, tokens, allocator);
                            return @unionInit(T, field.name, payload);
                        }
                    }
                }
                return error.MalformedSessionLog;
            } else {
                @compileError("unsupported event field: untagged union " ++ @typeName(T));
            }
        },
        .array => |array| {
            // Fixed-size array (e.g. [6]Color): consume one element per cell,
            // mirroring appendEventScalar's flattening.
            var result: T = undefined;
            inline for (0..array.len) |index| {
                result[index] = try parseScalarTokens(array.child, tokens, allocator);
            }
            return result;
        },
        else => @compileError("unsupported event field type: " ++ @typeName(T)),
    }
}

test "writeEventLog serializes representative event shapes" {
    const allocator = std.testing.allocator;

    const history = [_]Event{
        // void payload
        .{ .meta_event = .open_main_menu },
        // empty struct payload (zero fields — the accelerating pacing wait;
        // the group serializes as just the `event` discriminator line)
        .{ .meta_event = .{ .accelerating_wait = .{} } },
        // struct with a Vector2
        .{ .player_input_event = .{ .move_player = .{ .destination = .{ .x = 3, .y = 4 } } } },
        // optional present (target) + enum
        .{ .level_event = .{ .use_skill = .{
            .caster_index = 0,
            .skill_id = .slice,
            .target = .{ .x = 2, .y = 5 },
        } } },
        // optional absent (target null) -> the line is omitted
        .{ .level_event = .{ .use_skill = .{
            .caster_index = 1,
            .skill_id = .slice,
            .target = null,
        } } },
        // bool fields (via defaults)
        .{ .sub_level_event = .{ .attack = .{
            .attacker_index = 0,
            .defender_index = 3,
            .outgoing_damage = 12,
        } } },
        // signed int
        .{ .sub_level_event = .{ .change_momentum = .{ .entity_index = 2, .delta = -1 } } },
        // slice of structs (flattened) + an empty slice
        .{ .level_event = .{ .highlight_tiles = .{ .tile_positions = &.{
            .{ .x = 1, .y = 2 },
            .{ .x = 3, .y = 4 },
        } } } },
        .{ .level_event = .{ .highlight_tiles = .{ .tile_positions = &.{} } } },
        // string + Materials struct
        .{ .super_event = .{ .save_clone_info = .{
            .mission_uuid = "uuid-1",
            .mission_name = "first_mission",
            .total_turns = 7,
            .total_materials = .{ .wood = 1, .metal = 2, .leather = 3, .cloth = 4, .knowledge = 5 },
        } } },
        // nested tagged union payload: void tag (EditorToolId.select) and
        // index tag (EditorToolId.entity_type 2)
        .{ .editor_event = .{ .editor_set_tool = .{ .tool = .select } } },
        .{ .editor_event = .{ .editor_set_tool = .{ .tool = .{ .entity_type = 2 } } } },
        .{ .player_input_event = .{ .player_set_editor_tool = .{ .tool = .tile } } },
        // Selectable union payloads: struct tag (tile → Vector2 fields),
        // index tag, void tag (singletons)
        .{ .editor_event = .{ .editor_select = .{ .entry = .{ .tile = .{ .x = 3, .y = 4 } } } } },
        .{ .editor_event = .{ .editor_select = .{ .entry = .{ .entity_placement = 1 } } } },
        .{ .editor_event = .{ .editor_deselect = .{ .entry = .player_start } } },
        // selection move: the delta + the commit worklist (a slice of
        // unions with struct + bare-Vector2 tags)
        .{ .player_input_event = .{ .player_move_editor_selection = .{ .delta = .{ .x = 2, .y = -1 } } } },
        .{ .editor_event = .{ .editor_commit_selection_move = .{ .entries = &.{
            .{ .entity = .{ .type_id = 0, .position = .{ .x = 5, .y = 5 } } },
            .{ .tile = .{ .x = 6, .y = 6 } },
            .{ .player_start = .{ .x = 7, .y = 7 } },
        }, .next_index = 1 } } },
        // Item-def commits: FLATTENED top-level fields — the name is a
        // top-level string, so multi-word names ("New Sword") round-trip
        // (a nested Item payload's name would break the token regrouping —
        // see the editor_set_item_def comment in events.zig).
        .{ .player_input_event = .{ .player_set_editor_item_def = .{
            .type_id = 1,
            .item_kind = .weapon,
            .weapon_type = .sword,
            .name = "New Sword",
            .weapon_damage = 3,
        } } },
        .{ .player_input_event = .{ .player_set_editor_item_name = .{
            .type_id = 1,
            .value = "Iron Sword of Doom",
        } } },
        // The unified equipped-slot commit (FLATTENED): a multi-word weapon
        // name — the exact payload that used to break log reload when the
        // event carried a nested `?Weapon` — plus the clear case
        // (`equipped false`).
        .{ .player_input_event = .{ .player_set_editor_entity_gear = .{
            .target = .{ .entity_type = 0 },
            .slot = .main_hand,
            .equipped = true,
            .weapon_type = .sword,
            .name = "New Sword",
            .weapon_damage = 3,
        } } },
        .{ .editor_event = .{ .editor_set_entity_gear = .{
            .target = .player_def,
            .slot = .amulet,
            .equipped = false,
        } } },
        // Layer events + the def's layers slice: sprite strings with
        // SPACES (a mission dir named "My Mission") round-trip — the
        // layer events carry flat top-level sprite fields, and the
        // string-bearing struct slice takes the indexed multi-line
        // encoding (layers_count + layers_0_sprite ... lines).
        .{ .player_input_event = .{ .player_set_editor_entity_layer = .{
            .target = .{ .entity_type = 0 },
            .layer_index = 1,
            .sprite = "custom/My Mission/canopy",
            .color_index = 2,
        } } },
        .{ .editor_event = .{ .editor_add_decoration_layer = .{
            .type_id = 0,
            .sprite = "custom/My Mission/moss",
            .color_index = 1,
            .pixel_dims = .{ .x = 512, .y = 256 },
        } } },
        .{ .player_input_event = .{ .player_set_editor_decoration_def = .{
            .type_id = 0,
            .sprite = "tree_1",
            .footprint = &.{.{ .x = 0, .y = 0 }},
            .pixel_dims = .{ .x = 512, .y = 768 },
            .color_index = 3,
            .layers = &.{
                .{ .sprite = "custom/My Mission/canopy", .color_index = 2, .pixel_dims = .{ .x = 512, .y = 768 } },
                .{ .sprite = "tree_1_canopy", .color_index = 1, .behind = true, .pixel_dims = .{ .x = 512, .y = 768 } },
            },
        } } },
    };

    const output = try writeEventLog(&history, "20260815_143022", allocator);
    defer allocator.free(output);

    // Metadata header
    try std.testing.expect(std.mem.indexOf(u8, output, "file_format_version 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "game_version ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "created 20260815_143022\n") != null);

    // Discriminators + field shapes
    try std.testing.expect(std.mem.indexOf(u8, output, "event meta_event open_main_menu\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event meta_event accelerating_wait\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event move_player\ndestination 3 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event use_skill\ncaster_index 0\nskill_id slice\ntarget 2 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "outgoing_damage 12\ntriggers_effects true\nheals_attacker false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "delta -1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mission_name first_mission\ntotal_turns 7\ntotal_materials 1 2 3 4 5\n") != null);
    // Slice of Vector2 flattened; empty slice writes an empty value.
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event highlight_tiles\ntile_positions 1 2 3 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event highlight_tiles\ntile_positions \n") != null);

    // Null optional omits its line: only the PRESENT use_skill's group
    // carries a target line (the null one's `skill_id` line is directly
    // followed by the next event's discriminator). Adjacency proves it —
    // a bare "\ntarget " count can't (many events carry target lines).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "skill_id slice\ntarget 2 5\n"));

    // Nested tagged-union payload: `<tag> <payload-fields...>` (void tags
    // carry no payload fields).
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_set_tool\ntool select\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_set_tool\ntool entity_type 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event player_set_editor_tool\ntool tile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_select\nentry tile 3 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_select\nentry entity_placement 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_deselect\nentry player_start\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event player_move_editor_selection\ndelta 2 -1\n") != null);
    // The worklist slice: each entry flattens as `<tag> <payload fields...>`.
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_commit_selection_move\nentries entity 0 5 5 tile 6 6 player_start 7 7\nnext_index 1\n") != null);
    // The item-def commit: every field a top-level line — the multi-word
    // name rides one `name` line verbatim (the flattening's whole point).
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event player_set_editor_item_def\ntype_id 1\nitem_kind weapon\nweapon_type sword\nname New Sword\nweapon_damage 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event player_set_editor_item_name\ntype_id 1\nvalue Iron Sword of Doom\n") != null);
    // The gear-slot commit: every field a top-level line — the multi-word
    // weapon name rides one `name` line verbatim (the bug this shape
    // fixes: a nested `?Weapon` payload's name broke the token regrouping).
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event player_set_editor_entity_gear\ntarget entity_type 0\nslot main_hand\nequipped true\nweapon_type sword\nname New Sword\nweapon_damage 3\n") != null);
    // The clear: `equipped false`, the defaulted fields riding along.
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_set_entity_gear\ntarget player_def\nslot amulet\nequipped false\nweapon_type sword\nname \nweapon_damage 0\n") != null);
    // The layer events: flat top-level sprite fields — spaces ride the
    // sprite's own line verbatim.
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event player_set_editor_entity_layer\ntarget entity_type 0\nlayer_index 1\nsprite custom/My Mission/canopy\ncolor_index 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_add_decoration_layer\ntype_id 0\nsprite custom/My Mission/moss\ncolor_index 1\nbehind false\npixel_dims 512 256\n") != null);
    // The def's layers slice: the INDEXED encoding — one line per element
    // field, each string on its own line (the footprint slice stays a
    // single flattened line — no strings inside).
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event player_set_editor_decoration_def\ntype_id 0\nsprite tree_1\nfootprint 0 0\npixel_dims 512 768\ncolor_index 3\nkeep_original_colors false\nlayers_count 2\nlayers_0_sprite custom/My Mission/canopy\nlayers_0_color_index 2\nlayers_0_behind false\nlayers_0_pixel_dims 512 768\nlayers_1_sprite tree_1_canopy\nlayers_1_color_index 1\nlayers_1_behind true\nlayers_1_pixel_dims 512 768\n") != null);

    // The output round-trips through the generic config parser structurally:
    // Metadata + EventLog sections, with one entry group per event.
    const sections = try parseConfigFile(output, allocator);
    defer freeParsedSections(sections, allocator);
    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expectEqualStrings("Metadata", sections[0].header);
    try std.testing.expectEqualStrings("EventLog", sections[1].header);
    try std.testing.expectEqual(history.len, sections[1].entry_groups.len);
    // Each event group begins with the decorative `event_index` header, then
    // the `event` discriminator (event_index is purely for human readability
    // — the reader ignores it).
    try std.testing.expectEqualStrings("event_index", sections[1].entry_groups[0].pairs[0].key);
    try std.testing.expectEqualStrings("0", sections[1].entry_groups[0].pairs[0].value);
    try std.testing.expectEqualStrings("event", sections[1].entry_groups[0].pairs[1].key);
    try std.testing.expectEqualStrings("meta_event open_main_menu", sections[1].entry_groups[0].pairs[1].value);

    // The union-payload events round-trip through loadEventLog with their
    // tags + payloads intact (write → parse → load → expectEqualDeep). The
    // loaded log lives in an arena (no per-event free helper exists —
    // callers are arena-backed; leak-checked loading is the pending
    // exhaustive round-trip TODO's job).
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const log = try loadEventLog(sections, arena.allocator());
        for (0..2) |index| {
            try std.testing.expectEqualDeep(history[index], log.events[index]);
        }
        for (0..13) |offset| {
            try std.testing.expectEqualDeep(history[history.len - 13 + offset], log.events[log.events.len - 13 + offset]);
        }
    }
}

