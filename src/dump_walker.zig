//! Field-path reflection over the game's live objects - the console
//! `dump <path>` verb (see DESIGN → Input → Console input → dump paths).
//! A path is a Zig member-access expression evaluated read-only against
//! the root object the driver holds (the FrameState): field names, union
//! tag names, and `[n]` indexes, e.g. `history.current_state.hub.player.position`.
//! Names mirror the types exactly - renaming a field renames its dump
//! path, and a dead path errors truthfully instead of going stale.
//!
//! Safety invariants (a dump must never be able to mutate or execute):
//! - The root is `*const`; const propagates through every read, so any
//!   mutation in this file is a compile error.
//! - Raw pointers are NEVER followed (rendered `<pointer>`) - no vtable,
//!   allocator, or function pointer is ever dereferenced, and pointer
//!   cycles are unreachable by construction.
//! - No method is ever called on a walked value - only field memory
//!   reads and `@typeInfo`. A Zig method is arbitrary code; the walker's
//!   contract is that walking executes none.
//! - Union descent is active-tag-checked (reading an inactive union
//!   payload is undefined behavior - the mismatch is a truthful error
//!   line instead).
//! - Indexes are bounds-checked; slice rendering is capped.
//!
//! Rendering (type-determined - how a value prints depends only on its
//! type, never on where the path ends): detail propagates through
//! optionals, unions, and slices; struct fields cut to one-line
//! summaries (the compact form when the value fits one line, else the
//! first-`max_summary_fields` inline summary - compact fields verbatim,
//! stopping at the first non-compact field's summary token; nested
//! summaries never nest). Leaf conventions are the session-log writer's
//! (ints decimal, bools true/false, enums → tagName, strings verbatim).
//! Writes are best-effort - a failed write silently truncates the dump
//! (the diagnostics-write convention: never surfaces as a crash).

const std = @import("std");

/// Elements printed per addressed slice before the truncation note.
const max_slice_elements_printed: usize = 100;

/// A slice renders inline (compact) at this length or below; longer
/// slices render element-per-line (addressed) or a `([N] of T)` summary
/// (nested).
const max_inline_slice_elements: usize = 8;

/// Fields rendered in a non-compact struct's inline summary - see
/// `writeStructSummary`.
const max_summary_fields: usize = 4;

// ============================================================
// Path parsing
// ============================================================

const Step = union(enum) {
    /// A struct field name or a union tag name.
    field: []const u8,
    /// A slice/array index.
    index: usize,
};

const max_steps: usize = 64;

const ParseResult = union(enum) {
    ok: usize,
    err: []const u8,
};

/// Parse a dump path into resolution steps. Grammar: dot-separated
/// segments, each an identifier (`[A-Za-z_][A-Za-z0-9_]*`) with zero or
/// more `[n]` index suffixes. An empty path parses to zero steps (the
/// root table of contents).
fn parsePath(path: []const u8, steps: *[max_steps]Step) ParseResult {
    var count: usize = 0;
    var index: usize = 0;
    while (index < path.len) {
        // Identifier: a field name (struct) or tag name (union).
        if (!isIdentifierStart(path[index]))
            return .{ .err = "path must start with (and each '.' must be followed by) a field or tag name" };
        const name_start = index;
        index += 1;
        while (index < path.len and isIdentifierChar(path[index])) index += 1;
        if (count >= max_steps) return .{ .err = "path has too many segments (max 64)" };
        steps[count] = .{ .field = path[name_start..index] };
        count += 1;
        // Index suffixes: `[12]`, chainable for nested arrays.
        while (index < path.len and path[index] == '[') {
            index += 1;
            const digits_start = index;
            while (index < path.len and std.ascii.isDigit(path[index])) index += 1;
            if (index == digits_start) return .{ .err = "empty '[]' - expected a number" };
            if (index >= path.len or path[index] != ']')
                return .{ .err = "expected ']' after the index" };
            const parsed = std.fmt.parseInt(usize, path[digits_start..index], 10) catch
                return .{ .err = "index is too large" };
            index += 1;
            if (count >= max_steps) return .{ .err = "path has too many segments (max 64)" };
            steps[count] = .{ .index = parsed };
            count += 1;
        }
        if (index >= path.len) break;
        if (path[index] != '.')
            return .{ .err = "unexpected character in path - only letters, digits, '_', '.', '[' and ']'" };
        index += 1;
        if (index >= path.len) return .{ .err = "path ends with '.' - expected a name after it" };
    }
    return .{ .ok = count };
}

fn isIdentifierStart(char: u8) bool {
    return (char >= 'A' and char <= 'Z') or (char >= 'a' and char <= 'z') or char == '_';
}

fn isIdentifierChar(char: u8) bool {
    return isIdentifierStart(char) or (char >= '0' and char <= '9');
}

// ============================================================
// Entry point
// ============================================================

/// Resolve `path` against `root` and write the dump to `output`. An
/// empty path renders the root's table of contents (one level of field
/// names - the discovery entry point). Resolution failures write a
/// `dump error: ...` line naming what is actually there (fields, active
/// tag, element count) - the error teaches the next path.
pub fn writeDump(output: *std.Io.Writer, root: anytype, path: []const u8) void {
    // Const-assert the root: whatever pointer the caller holds is read
    // as const from here down - the no-mutation invariant is compiler-
    // enforced, not conventional.
    const const_root: *const @TypeOf(root.*) = root;
    var steps: [max_steps]Step = undefined;
    switch (parsePath(path, &steps)) {
        .ok => |count| walk(output, 0, const_root.*, steps[0..count]),
        .err => |message| dumpError(output, "{s}", .{message}),
    }
}

// ============================================================
// Resolution + rendering (one pass)
// ============================================================

fn writeIndentation(output: *std.Io.Writer, indent: usize) void {
    for (0..indent) |_| output.writeAll("  ") catch return;
}

/// Resolve one step into `value`, then render it once the path is
/// exhausted. Every failure mode is a truthful error line, never a
/// panic, never a mutation.
fn walk(output: *std.Io.Writer, indent: usize, value: anytype, steps: []const Step) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (steps.len == 0) {
                writeAddressed(output, indent, value);
                return;
            }
            switch (steps[0]) {
                .index => dumpError(output, "{s} is a struct - address a field by name, not an index", .{@typeName(T)}),
                .field => |name| {
                    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
                        if (std.mem.eql(u8, name, field_name)) {
                            if (comptime isEmptyUnion(field_type)) {
                                dumpError(output, "{s} is a union with no variants - nothing to address", .{@typeName(field_type)});
                                return;
                            }
                            walk(output, indent, @field(value, field_name), steps[1..]);
                            return;
                        }
                    }
                    dumpErrorNoField(output, T, name);
                },
            }
        },
        .@"union" => {
            if (steps.len == 0) {
                writeAddressed(output, indent, value);
                return;
            }
            switch (steps[0]) {
                .index => dumpError(output, "{s} is a union - address a tag by name, not an index", .{@typeName(T)}),
                .field => |name| {
                    inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types) |field_name, field_type| {
                        if (std.mem.eql(u8, name, field_name)) {
                            if (comptime isEmptyUnion(field_type)) {
                                dumpError(output, "{s} is a union with no variants - nothing to address", .{@typeName(field_type)});
                                return;
                            }
                            // The active-tag check MUST precede the payload
                            // read: accessing an inactive union field is
                            // undefined behavior (the compiler's own safety
                            // check would panic - the dump errors instead).
                            if (!std.mem.eql(u8, @tagName(value), field_name)) {
                                dumpError(
                                    output,
                                    "{s} is .{s}, not .{s} - address the active tag",
                                    .{ @typeName(T), @tagName(value), name },
                                );
                                return;
                            }
                            if (comptime field_type == void) {
                                // A void variant: the tag IS the value -
                                // addressing it echoes the tag.
                                writeIndentation(output, indent);
                                output.print(".{s}\n", .{name}) catch return;
                                return;
                            }
                            walk(output, indent, @field(value, field_name), steps[1..]);
                            return;
                        }
                    }
                    dumpErrorNoTag(output, T, name);
                },
            }
        },
        .optional => {
            if (value) |payload| {
                walk(output, indent, payload, steps);
            } else if (steps.len == 0) {
                output.writeAll("null\n") catch return;
            } else {
                dumpError(output, "{s} is null - nothing beneath", .{@typeName(T)});
            }
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child == u8) {
                    // A byte slice is a string (leaf) - printed verbatim,
                    // not element-wise.
                    if (steps.len > 0) {
                        dumpError(output, "a string is a leaf - no '{s}' beneath it", .{steps[0].field});
                    } else {
                        output.print("{s}\n", .{value}) catch return;
                    }
                    return;
                }
                if (steps.len == 0) {
                    writeAddressed(output, indent, value);
                    return;
                }
                switch (steps[0]) {
                    .index => |index| {
                        if (index >= value.len) {
                            dumpError(
                                output,
                                "index {d} out of bounds - {d} elements",
                                .{ index, value.len },
                            );
                            return;
                        }
                        walk(output, indent, value[index], steps[1..]);
                    },
                    .field => dumpError(
                        output,
                        "a slice of {s} - index it ([n]), don't name it",
                        .{@typeName(pointer.child)},
                    ),
                }
            },
            // The safety boundary: raw pointers are never followed.
            else => {
                if (steps.len > 0) {
                    dumpError(output, "{s} is a pointer - pointers are never followed", .{@typeName(T)});
                } else {
                    output.writeAll("<pointer>\n") catch return;
                }
            },
        },
        .array => |array| {
            if (steps.len == 0) {
                writeAddressed(output, indent, value);
                return;
            }
            switch (steps[0]) {
                .index => |index| {
                    if (index >= array.len) {
                        dumpError(output, "index {d} out of bounds - {d} elements", .{ index, array.len });
                        return;
                    }
                    walk(output, indent, value[index], steps[1..]);
                },
                .field => dumpError(
                    output,
                    "an array of {s} - index it ([n]), don't name it",
                    .{@typeName(array.child)},
                ),
            }
        },
        .int, .float, .bool, .@"enum", .void => {
            if (steps.len > 0) {
                dumpError(
                    output,
                    "{s} is a leaf - no '{s}' beneath it",
                    .{ @typeName(T), switch (steps[0]) {
                        .field => |name| name,
                        .index => "[n]",
                    } },
                );
            } else {
                writeIndentation(output, indent);
                writeCompactForm(output, value);
                output.writeAll("\n") catch return;
            }
        },
        // Anything exotic (function values, opaque types, ...) - opaque.
        else => {
            if (steps.len > 0) {
                dumpError(output, "{s} is not introspectable", .{@typeName(T)});
            } else {
                output.writeAll("<opaque>\n") catch return;
            }
        },
    }
}

// ============================================================
// Rendering
// ============================================================

/// An uninhabited union - declared with no variants (a "none yet"
/// placeholder, e.g. ReplayViewerEvent). No value of this type can exist,
/// and `@field` on an access to such a field cannot even LOWER - every
/// recursion site guards with this before touching the value.
fn isEmptyUnion(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .@"union" and info.@"union".field_names.len == 0;
}

/// Render the value the path ADDRESSED (the path is exhausted): full
/// detail through containers (optional/union/slice), struct fields as
/// one-line summaries.
fn writeAddressed(output: *std.Io.Writer, indent: usize, value: anytype) void {
    const T = @TypeOf(value);
    if (valueIsCompact(value)) {
        writeIndentation(output, indent);
        writeCompactForm(output, value);
        output.writeAll("\n") catch return;
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => {
            // One level: each field as `name: <one-line summary>`. Nested
            // non-compact values appear as their type name - descend by
            // path for their contents.
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
                writeIndentation(output, indent);
                output.print("{s}: ", .{field_name}) catch return;
                if (comptime isEmptyUnion(field_type)) {
                    output.writeAll("<uninhabited>") catch return;
                } else {
                    writeSummaryInline(output, @field(value, field_name));
                }
                output.writeAll("\n") catch return;
            }
        },
        .@"union" => {
            // The active tag is the headline; the payload is addressed
            // (unions always show through - a tag without its payload
            // says nothing).
            writeIndentation(output, indent);
            output.print(".{s}\n", .{@tagName(value)}) catch return;
            switch (value) {
                inline else => |payload| {
                    if (comptime isEmptyUnion(@TypeOf(payload))) {
                        // No payload exists - the tag line above said it all.
                    } else {
                        writeAddressed(output, indent + 1, payload);
                    }
                },
            }
        },
        .optional => {
            if (value) |payload| writeAddressed(output, indent, payload);
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child == u8) {
                    writeIndentation(output, indent);
                    output.print("{s}\n", .{value}) catch return;
                    return;
                }
                writeSliceElements(output, indent, value);
            },
            else => {
                writeIndentation(output, indent);
                output.writeAll("<pointer>\n") catch return;
            },
        },
        .array => writeSliceElements(output, indent, value),
        else => {
            writeIndentation(output, indent);
            output.writeAll("<opaque>\n") catch return;
        },
    }
}

/// Render slice/array elements, one line each (element summaries), with
/// the length cap + truncation note.
fn writeSliceElements(output: *std.Io.Writer, indent: usize, slice: anytype) void {
    const limit = @min(slice.len, max_slice_elements_printed);
    for (slice[0..limit], 0..) |element, index| {
        writeIndentation(output, indent);
        output.print("[{d}]: ", .{index}) catch return;
        writeSummaryInline(output, element);
        output.writeAll("\n") catch return;
    }
    if (slice.len > limit) {
        writeIndentation(output, indent);
        output.print("(+{d} more - address by index)\n", .{slice.len - limit}) catch return;
    }
}

/// Write a value as a single line, no indent, no newline - the form used
/// for struct fields and slice elements. Compact values render fully;
/// a non-compact struct renders its first-fields inline summary (see
/// `writeStructSummary`); unions keep their tag chain (the most
/// interesting fact about a union is which variant it is); everything
/// else renders its summary token.
fn writeSummaryInline(output: *std.Io.Writer, value: anytype) void {
    const T = @TypeOf(value);
    if (valueIsCompact(value)) {
        writeCompactForm(output, value);
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => writeStructSummary(output, value),
        .@"union" => {
            output.print(".{s}", .{@tagName(value)}) catch return;
            switch (value) {
                inline else => |payload| {
                    if (@TypeOf(payload) != void) {
                        output.writeAll(" ") catch return;
                        if (comptime isEmptyUnion(@TypeOf(payload))) {
                            output.writeAll("<uninhabited>") catch return;
                        } else {
                            writeSummaryInline(output, payload);
                        }
                    }
                },
            }
        },
        .optional => {
            if (value) |payload| writeSummaryInline(output, payload);
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => output.print("({d} of {s})", .{ value.len, @typeName(pointer.child) }) catch return,
            else => output.writeAll("<pointer>") catch return,
        },
        .array => |array| output.print("({d} of {s})", .{ array.len, @typeName(array.child) }) catch return,
        else => output.writeAll("<opaque>") catch return,
    }
}

/// A non-compact struct's inline summary: the first
/// `max_summary_fields` fields in DECLARATION order as
/// `{ name: value, ... }` - compact values render verbatim, and the first
/// non-compact field renders its summary token and ENDS the summary (the
/// line stays short; descend by path for the rest). Declaration order,
/// not a per-type field list: the walker's type-determined rendering rule
/// (how a value prints depends only on its type, never on where the path
/// ends) - an Entity-dedicated field list would be the forbidden special
/// case. Summaries never NEST: non-compact values inside a summary render
/// via `writeSummaryToken`, whose struct arm is the bare type name.
fn writeStructSummary(output: *std.Io.Writer, value: anytype) void {
    const T = @TypeOf(value);
    output.writeAll("{ ") catch return;
    var rendered: usize = 0;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
        if (rendered >= max_summary_fields) break;
        if (comptime field_type == void) continue;
        if (comptime isEmptyUnion(field_type)) continue;
        if (rendered > 0) output.writeAll(", ") catch return;
        output.print("{s}: ", .{field_name}) catch return;
        const field_value = @field(value, field_name);
        if (valueIsCompact(field_value)) {
            writeCompactForm(output, field_value);
            rendered += 1;
        } else {
            writeSummaryToken(output, field_value);
            break;
        }
    }
    output.writeAll(" }") catch return;
}

/// The token form used INSIDE a struct summary: identical to
/// `writeSummaryInline` for everything except a nested struct, which
/// renders its TYPE NAME - summaries never nest (one `{ ... }` summary
/// per line; a struct-inside-summary descends by path instead).
fn writeSummaryToken(output: *std.Io.Writer, value: anytype) void {
    const T = @TypeOf(value);
    if (valueIsCompact(value)) {
        writeCompactForm(output, value);
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => output.print("<{s}>", .{@typeName(T)}) catch return,
        .@"union" => {
            output.print(".{s}", .{@tagName(value)}) catch return;
            switch (value) {
                inline else => |payload| {
                    if (@TypeOf(payload) != void) {
                        output.writeAll(" ") catch return;
                        if (comptime isEmptyUnion(@TypeOf(payload))) {
                            output.writeAll("<uninhabited>") catch return;
                        } else {
                            writeSummaryToken(output, payload);
                        }
                    }
                },
            }
        },
        .optional => {
            if (value) |payload| writeSummaryToken(output, payload);
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => output.print("({d} of {s})", .{ value.len, @typeName(pointer.child) }) catch return,
            else => output.writeAll("<pointer>") catch return,
        },
        .array => |array| output.print("({d} of {s})", .{ array.len, @typeName(array.child) }) catch return,
        else => output.writeAll("<opaque>") catch return,
    }
}

/// Write a value in its compact (single-line) form - only called when
/// `valueIsCompact` said it fits.
fn writeCompactForm(output: *std.Io.Writer, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .float => output.print("{d}", .{value}) catch return,
        .bool => output.print("{}", .{value}) catch return,
        .@"enum" => output.print("{s}", .{@tagName(value)}) catch return,
        .void => {},
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child == u8) {
                    output.print("{s}", .{value}) catch return;
                    return;
                }
                output.writeAll("[") catch return;
                for (value, 0..) |element, index| {
                    if (index > 0) output.writeAll(", ") catch return;
                    writeCompactForm(output, element);
                }
                output.writeAll("]") catch return;
            },
            else => output.writeAll("<pointer>") catch return,
        },
        .optional => {
            if (value) |payload| {
                writeCompactForm(output, payload);
            } else {
                output.writeAll("null") catch return;
            }
        },
        .@"union" => {
            output.print(".{s}", .{@tagName(value)}) catch return;
            switch (value) {
                inline else => |payload| {
                    if (@TypeOf(payload) != void and !comptime isEmptyUnion(@TypeOf(payload))) {
                        output.writeAll(" ") catch return;
                        writeCompactForm(output, payload);
                    }
                },
            }
        },
        .@"struct" => {
            output.writeAll("{ ") catch return;
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, 0..) |field_name, field_type, field_index| {
                if (field_index > 0) output.writeAll(", ") catch return;
                output.print("{s}: ", .{field_name}) catch return;
                if (comptime isEmptyUnion(field_type)) {
                    output.writeAll("<uninhabited>") catch return;
                } else {
                    writeCompactForm(output, @field(value, field_name));
                }
            }
            output.writeAll(" }") catch return;
        },
        .array => {
            output.writeAll("[") catch return;
            for (value, 0..) |element, index| {
                if (index > 0) output.writeAll(", ") catch return;
                writeCompactForm(output, element);
            }
            output.writeAll("]") catch return;
        },
        else => output.writeAll("<opaque>") catch return,
    }
}

/// Whether a value fits one line (the compact form). Value-dependent for
/// unions (the active payload), optionals, and slice lengths; computed
/// by the same recursion the compact form uses, so the two cannot
/// disagree.
fn valueIsCompact(value: anytype) bool {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum", .void, .@"opaque", .@"fn", .error_set => true,
        .pointer => |pointer| switch (pointer.size) {
            .slice => slice_is_string: {
                if (pointer.child == u8) break :slice_is_string true;
                if (value.len > max_inline_slice_elements) break :slice_is_string false;
                for (value) |element| {
                    if (!valueIsCompact(element)) break :slice_is_string false;
                }
                break :slice_is_string true;
            },
            else => true,
        },
        .optional => if (value) |payload| valueIsCompact(payload) else true,
        .@"union" => switch (value) {
            inline else => |payload| comptime_white: {
                if (comptime isEmptyUnion(@TypeOf(payload))) break :comptime_white true;
                break :comptime_white valueIsCompact(payload);
            },
        },
        .@"struct" => all_fields_compact: {
            inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, field_type| {
                if (comptime isEmptyUnion(field_type)) continue;
                if (!valueIsCompact(@field(value, field_name))) break :all_fields_compact false;
            }
            break :all_fields_compact true;
        },
        .array => |array| all_elements_compact: {
            if (array.len > max_inline_slice_elements) break :all_elements_compact false;
            for (value) |element| {
                if (!valueIsCompact(element)) break :all_elements_compact false;
            }
            break :all_elements_compact true;
        },
        else => true,
    };
}

// ============================================================
// Errors (truthful - they name what is actually there)
// ============================================================

fn dumpError(output: *std.Io.Writer, comptime format: []const u8, args: anytype) void {
    output.print("dump error: " ++ format ++ "\n", args) catch return;
}

fn dumpErrorNoField(output: *std.Io.Writer, comptime T: type, wanted: []const u8) void {
    output.print("dump error: no field '{s}' on {s} - fields: ", .{ wanted, @typeName(T) }) catch return;
    inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, field_index| {
        if (field_index > 0) output.writeAll(", ") catch return;
        output.print("{s}", .{field_name}) catch return;
    }
    output.writeAll("\n") catch return;
}

fn dumpErrorNoTag(output: *std.Io.Writer, comptime T: type, wanted: []const u8) void {
    output.print("dump error: no tag '{s}' on {s} - tags: ", .{ wanted, @typeName(T) }) catch return;
    inline for (@typeInfo(T).@"union".field_names, 0..) |field_name, field_index| {
        if (field_index > 0) output.writeAll(", ") catch return;
        output.print("{s}", .{field_name}) catch return;
    }
    output.writeAll("\n") catch return;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// A synthetic tree mirroring the game's shapes: compact leaves, a
/// compact struct, slices, optionals, a union with void/leaf/slice
/// payloads, and a pointer field.
const TestLeaf = struct { x: i32, y: i32 };
/// 12 compact elements - over the inline cap, so a slice of it is
/// NON-compact (the tail that trips the summary path below).
const summary_skills: [12]TestLeaf = @splat(.{ .x = 9, .y = 9 });
/// Entity-shaped for the summary tests: compact lead fields, then a
/// non-compact slice that stops the summary.
const TestSummaryBig = struct {
    name: []const u8 = "roster entry",
    team: u32 = 2,
    position: TestLeaf = .{ .x = 1, .y = 2 },
    skills: []const TestLeaf = &summary_skills,
    extra: u32 = 55,
};
/// Non-compact only via its tail blob: exercises the field cap (all five
/// lead fields are compact, the cap renders four).
const TestSummaryWide = struct {
    a: u32 = 1,
    b: u32 = 2,
    c: u32 = 3,
    d: u32 = 4,
    e: u32 = 5,
    blob: []const TestLeaf = &summary_skills,
};
/// A struct whose FIRST field is non-compact: exercises the one-level
/// guard (a summary never contains another summary).
const TestSummaryHolder = struct {
    big: TestSummaryBig = .{},
    tail: u32 = 8,
};
const TestMode = enum { on, off };
const TestUnion = union(enum) { nothing: void, one: TestLeaf, label: []const u8 };
const TestChild = struct {
    name: []const u8,
    count: u32,
    flag: bool,
    mode: TestMode,
};
const TestRoot = struct {
    title: []const u8,
    mode: TestMode,
    leaf: TestLeaf,
    opt_leaf: ?TestLeaf,
    opt_null: ?TestLeaf,
    child: TestChild,
    ptr: ?*const TestLeaf,
    few: []const TestLeaf,
    /// Long enough that the root is NON-compact - the ToC (field-per-line)
    /// shape, like the real FrameState root.
    many: []const TestLeaf,
    tagged: TestUnion,
    tagged_label: TestUnion,
    tagged_nothing: TestUnion,
};

fn testRoot() TestRoot {
    const few = [_]TestLeaf{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const many = @as([12]TestLeaf, @splat(.{ .x = 0, .y = 0 }));
    return .{
        .title = "hello world",
        .mode = .on,
        .leaf = .{ .x = 5, .y = 6 },
        .opt_leaf = .{ .x = 7, .y = 8 },
        .opt_null = null,
        .child = .{ .name = "kid", .count = 9, .flag = true, .mode = .off },
        .ptr = null,
        .few = &few,
        .many = &many,
        .tagged = .{ .one = .{ .x = 1, .y = 1 } },
        .tagged_label = .{ .label = "tagged" },
        .tagged_nothing = .nothing,
    };
}

/// Dump `path` against `root_value` into `buffer`, returning the output
/// text (the fixed-writer view).
fn dumpToText(buffer: []u8, root_value: anytype, path: []const u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const root: *const @TypeOf(root_value) = &root_value;
    writeDump(&writer, root, path);
    return buffer[0..writer.end];
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, text, needle) != null);
}

test "dump walker: leaves, compact forms, and the root table of contents" {
    var buffer: [2048]u8 = undefined;
    const root = testRoot();

    // Empty path: the root ToC - one level, field names present.
    const toc = dumpToText(&buffer, root, "");
    try expectContains(toc, "title: hello world\n");
    try expectContains(toc, "mode: on\n");
    try expectContains(toc, "leaf: { x: 5, y: 6 }\n");
    try expectContains(toc, "opt_leaf: { x: 7, y: 8 }\n");
    try expectContains(toc, "opt_null: null\n");
    try expectContains(toc, "child: { name: kid, count: 9, flag: true, mode: off }\n");
    try expectContains(toc, "ptr: null\n");
    try expectContains(toc, "few: [{ x: 1, y: 2 }, { x: 3, y: 4 }]\n");
    try expectContains(toc, "many: (12 of dump_walker.TestLeaf)\n");
    try expectContains(toc, "tagged: .one { x: 1, y: 1 }\n");
    try expectContains(toc, "tagged_label: .label tagged\n");
    try expectContains(toc, "tagged_nothing: .nothing\n");

    // Leaf landings print the value alone.
    const title = dumpToText(&buffer, root, "title");
    try testing.expectEqualStrings("hello world\n", title);
    const leaf = dumpToText(&buffer, root, "leaf");
    try testing.expectEqualStrings("{ x: 5, y: 6 }\n", leaf);
}

test "dump walker: struct fields address by name; errors are truthful" {
    var buffer: [2048]u8 = undefined;
    const root = testRoot();

    const leaf_x = dumpToText(&buffer, root, "leaf.x");
    try testing.expectEqualStrings("5\n", leaf_x);

    const child_name = dumpToText(&buffer, root, "child.name");
    try testing.expectEqualStrings("kid\n", child_name);

    // Unknown field: the error lists what IS there.
    const no_field = dumpToText(&buffer, root, "child.nope");
    try expectContains(no_field, "dump error: no field 'nope' on");
    try expectContains(no_field, "fields: name, count, flag, mode");

    // Indexing a struct errors; naming a slice errors toward indexing.
    const index_on_struct = dumpToText(&buffer, root, "child[0]");
    try expectContains(index_on_struct, "is a struct - address a field by name");
    const name_on_slice = dumpToText(&buffer, root, "few.first");
    try expectContains(name_on_slice, "index it ([n]), don't name it");

    // Leaf with a deeper path errors.
    const through_leaf = dumpToText(&buffer, root, "leaf.x.deeper");
    try expectContains(through_leaf, "is a leaf - no 'deeper' beneath it");

    // Optional null: nothing beneath.
    const into_null = dumpToText(&buffer, root, "opt_null.x");
    try expectContains(into_null, "is null - nothing beneath");

    // Index bounds are checked.
    const out_of_bounds = dumpToText(&buffer, root, "few[2]");
    try expectContains(out_of_bounds, "index 2 out of bounds - 2 elements");
}

test "dump walker: unions descend by active tag; wrong tags error, not panic" {
    var buffer: [2048]u8 = undefined;
    const root = testRoot();

    // Active-tag descent: through the tag into the payload.
    const one = dumpToText(&buffer, root, "tagged.one");
    try testing.expectEqualStrings("{ x: 1, y: 1 }\n", one);
    const one_x = dumpToText(&buffer, root, "tagged.one.x");
    try testing.expectEqualStrings("1\n", one_x);

    // Wrong tag: the error names the ACTIVE tag (this is the guarded UB
    // path - a blind @field would panic).
    const wrong_tag = dumpToText(&buffer, root, "tagged.label");
    try expectContains(wrong_tag, "is .one, not .label - address the active tag");

    // Unknown tag: the error lists the tags.
    const no_tag = dumpToText(&buffer, root, "tagged.bogus");
    try expectContains(no_tag, "no tag 'bogus' on");
    try expectContains(no_tag, "tags: nothing, one, label");

    // A void payload renders as the bare tag.
    const nothing = dumpToText(&buffer, root, "tagged_nothing.nothing");
    try testing.expectEqualStrings(".nothing\n", nothing);
}

test "dump walker: slices render element-per-line with the cap + note" {
    var buffer: [8192]u8 = undefined;
    const many = @as([150]TestLeaf, @splat(.{ .x = 0, .y = 0 }));
    const root = struct {
        many: []const TestLeaf = &many,
        empty: []const TestLeaf = &.{},
    }{};

    // Addressed slice: one line per element, capped at 100.
    const addressed = dumpToText(&buffer, root, "many");
    try expectContains(addressed, "[0]: { x: 0, y: 0 }\n");
    try expectContains(addressed, "[99]: { x: 0, y: 0 }\n");
    try expectContains(addressed, "(+50 more - address by index)\n");
    try testing.expect(!std.mem.startsWith(u8, addressed, "[100]"));

    // An indexed element still resolves beneath the cap.
    const element = dumpToText(&buffer, root, "many[120]");
    try testing.expectEqualStrings("{ x: 0, y: 0 }\n", element);

    // An empty slice renders inline.
    const empty = dumpToText(&buffer, root, "empty");
    try testing.expectEqualStrings("[]\n", empty);

    // A long slice nested in a struct summarizes, leaving descent to the
    // path.
    const nested = struct { items: []const TestLeaf = &many }{};
    const summary = dumpToText(&buffer, nested, "");
    try expectContains(summary, "items: (150 of dump_walker.TestLeaf)\n");
}

test "dump walker: pointers are opaque - rendered, never followed" {
    var buffer: [2048]u8 = undefined;
    var pointee = TestLeaf{ .x = 1, .y = 2 };
    const PointerRoot = struct { ptr: *const TestLeaf };
    const root = PointerRoot{ .ptr = &pointee };

    // Set (non-null) pointer: rendered as an opaque token.
    const rendered = dumpToText(&buffer, root, "ptr");
    try testing.expectEqualStrings("<pointer>\n", rendered);

    // A path THROUGH a pointer errors - the walker never dereferences.
    const through = dumpToText(&buffer, root, "ptr.x");
    try expectContains(through, "is a pointer - pointers are never followed");
}

test "dump walker: parse errors name the syntax problem" {
    var buffer: [512]u8 = undefined;
    const root = testRoot();

    const leading_index = dumpToText(&buffer, root, "[0]");
    try expectContains(leading_index, "must start with");
    const trailing_dot = dumpToText(&buffer, root, "leaf.");
    try expectContains(trailing_dot, "expected a name after it");
    const unclosed = dumpToText(&buffer, root, "few[1");
    try expectContains(unclosed, "expected ']' after the index");
    const bad_char = dumpToText(&buffer, root, "leaf.x-$");
    try expectContains(bad_char, "unexpected character in path");
}

test "dump walker canary: a battery of deep paths mutates nothing and crashes nothing" {
    // The no-mutation/no-crash property over the REAL state types: walk
    // deep paths across GameState / SessionState / Settings /
    // event_history, then verify the state is bit-identical. Imports are
    // test-local so the game build never links the harness.
    const test_harness = @import("test_harness.zig");
    const deep_copy = @import("deep_copy.zig");
    const state_mod = @import("state.zig");
    const types = @import("types.zig");

    var backing = std.heap.ArenaAllocator.init(testing.allocator);
    defer backing.deinit();
    var harness = test_harness.Harness.init(backing.allocator());
    const tiles = [_]types.Vector2{
        .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 },
    };
    var history = harness.newHistory(test_harness.levelStateWithEntities(
        backing.allocator(),
        &.{.{ .name = "Player", .team = 0, .position = .{ .x = 0, .y = 0 } }},
        &tiles,
    ));
    test_harness.runToIdle(&history);

    // The root mirrors the driver's: history by value (the walker reads
    // the same fields FrameState would).
    const Root = struct { history: state_mod.GameStateHistory };
    const root = Root{ .history = history };

    const before = deep_copy.deepCopy(state_mod.GameState, root.history.current_state, backing.allocator());

    var buffer: [16384]u8 = undefined;
    const paths = [_][]const u8{
        "",
        "history",
        "history.current_state",
        "history.current_state.screen",
        "history.current_state.player_data",
        "history.current_state.level",
        "history.current_state.level.entities",
        "history.current_state.level.entities[0]",
        "history.current_state.level.entities[0].position",
        "history.current_state.level.entities[0].name",
        "history.current_state.level.level_tiles",
        "history.current_state.level.turn_phase",
        "history.current_state.ui_surfaces",
        "history.session",
        "history.session.tile_cursor",
        "history.session.input_state",
        "history.session.input_state.keys_held",
        "history.settings",
        "history.settings.player_name",
        "history.settings.input_bindings",
        "history.settings.input_bindings[0]",
        "history.settings.input_bindings[0].action",
        "history.event_history",
        "history.event_history.items",
        "history.initial_state",
        "history.io",
    };
    for (paths) |path| {
        _ = dumpToText(&buffer, root, path);
    }

    try testing.expect(deep_copy.deepEqual(state_mod.GameState, before, root.history.current_state));
}

test "dump walker: non-compact structs summarize their first fields inline" {
    var buffer: [4096]u8 = undefined;

    // The entity-like payoff: a slice element renders a readable one-line
    // summary instead of `<dump_walker.TestSummaryBig>` - compact fields
    // verbatim, stopping at the first non-compact field's token.
    const items = [_]TestSummaryBig{.{}};
    const roster = struct { items: []const TestSummaryBig = &items }{};
    const listed = dumpToText(&buffer, roster, "items");
    try expectContains(listed, "[0]: { name: roster entry, team: 2, position: { x: 1, y: 2 }, skills: (12 of dump_walker.TestLeaf) }\n");
    // The stop-at-first-non-compact rule: `extra` (after `skills`) never
    // renders inline - address it by path.
    try testing.expect(std.mem.indexOf(u8, listed, "extra") == null);
    const extra = dumpToText(&buffer, roster, "items[0].extra");
    try testing.expectEqualStrings("55\n", extra);

    // The field cap: five compact lead fields render four, the fifth stays
    // path-only (the struct is non-compact via its tail).
    const wide = struct { wide: TestSummaryWide = .{} }{};
    const capped = dumpToText(&buffer, wide, "");
    try expectContains(capped, "wide: { a: 1, b: 2, c: 3, d: 4 }\n");
    try testing.expect(std.mem.indexOf(u8, capped, "e: 5") == null);
    const fifth = dumpToText(&buffer, wide, "wide.e");
    try testing.expectEqualStrings("5\n", fifth);

    // The one-level guard: a summary never contains another summary - a
    // non-compact struct field renders its type token, the rest by path.
    const holder = struct { holder: TestSummaryHolder = .{} }{};
    const guarded = dumpToText(&buffer, holder, "");
    try expectContains(guarded, "holder: { big: <dump_walker.TestSummaryBig> }\n");
    const tail = dumpToText(&buffer, holder, "holder.tail");
    try testing.expectEqualStrings("8\n", tail);
}
