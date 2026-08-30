//! Session-log serialization/deserialization — the comptime-generic
//! writer + reader over the `Event` union (see DESIGN → Logging & Replay).
//! Separate from the config-file format layer (parser.zig): a session log is
//! `event_history` linearized to config sections, one entry group per event.
//! New events serialize/deserialize with no changes here (comptime reflection
//! over the union).

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
pub const session_log_file_format_version: u32 = 1;

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

/// Serialize an event history (+ a created timestamp) into a session-log file
/// body. `created` is expected as "YYYYMMDD_HHMMSS" but is written verbatim.
pub fn writeEventLog(
    event_history: []const Event,
    created: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;

    try buffer.appendSlice(allocator, "Metadata\n");
    try buffer.print(allocator, "file_format_version {d}\n", .{session_log_file_format_version});
    try buffer.print(allocator, "game_version {s}\n", .{build_info.game_version});
    try buffer.print(allocator, "created {s}\n", .{created});

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
            try buffer.appendSlice(allocator, name);
            try buffer.appendSlice(allocator, " ");
            try appendEventScalar(buffer, allocator, value);
            try buffer.appendSlice(allocator, "\n");
        },
    }
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
                // writes nothing (an empty value).
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
                            @field(payload, payload_field.name) = try parseEventFieldValue(
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
    };

    const output = try writeEventLog(&history, "20260815_143022", allocator);
    defer allocator.free(output);

    // Metadata header
    try std.testing.expect(std.mem.indexOf(u8, output, "file_format_version 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "game_version ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "created 20260815_143022\n") != null);

    // Discriminators + field shapes
    try std.testing.expect(std.mem.indexOf(u8, output, "event meta_event open_main_menu\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event move_player\ndestination 3 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event use_skill\ncaster_index 0\nskill_id slice\ntarget 2 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "outgoing_damage 12\ntriggers_effects true\nheals_attacker false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "delta -1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mission_name first_mission\ntotal_turns 7\ntotal_materials 1 2 3 4 5\n") != null);
    // Slice of Vector2 flattened; empty slice writes an empty value.
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event highlight_tiles\ntile_positions 1 2 3 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event level_event highlight_tiles\ntile_positions \n") != null);

    // Null optional omits its line: exactly one "target " across both use_skills.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\ntarget "));

    // Nested tagged-union payload: `<tag> <payload-fields...>` (void tags
    // carry no payload fields).
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_set_tool\ntool select\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_set_tool\ntool entity_type 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event player_input_event player_set_editor_tool\ntool tile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_select\nentry tile 3 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_select\nentry entity_placement 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "event editor_event editor_deselect\nentry player_start\n") != null);

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
        try std.testing.expectEqualDeep(history[history.len - 6], log.events[log.events.len - 6]);
        try std.testing.expectEqualDeep(history[history.len - 5], log.events[log.events.len - 5]);
        try std.testing.expectEqualDeep(history[history.len - 4], log.events[log.events.len - 4]);
        try std.testing.expectEqualDeep(history[history.len - 3], log.events[log.events.len - 3]);
        try std.testing.expectEqualDeep(history[history.len - 2], log.events[log.events.len - 2]);
        try std.testing.expectEqualDeep(history[history.len - 1], log.events[log.events.len - 1]);
    }
}

