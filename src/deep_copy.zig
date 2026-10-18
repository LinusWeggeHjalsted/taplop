//! Comptime-generic deep copy + deep equal over the game's types (slices,
//! optionals, tagged unions, structs, arrays, scalars). `deepCopy` clones
//! into an arena (backing snapshots/checkpoints); `deepEqual` +
//! `firstDiffField` drive replay verification (no floats in event payloads →
//! exact `==`). Auto-tracks new fields via reflection. See DESIGN → Replay &
//! Side Effects, Determinism & Tiebreaking → Replay VERIFICATION.

const std = @import("std");
/// - Slices are duplicated (elements deep-copied if they contain slices/pointers)
/// - Optionals are unwrapped and deep-copied if non-null
/// - Tagged unions have their active field deep-copied
/// - Structs have each field deep-copied
/// - Scalars, enums, bools, ints, floats pass through unchanged
///
/// Because this uses comptime reflection, it automatically handles new fields
/// added to any struct - no manual updating needed.
pub fn deepCopy(comptime T: type, value: T, allocator: std.mem.Allocator) T {
    const info = @typeInfo(T);

    switch (info) {
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (value.len == 0) return value;
                    const new_slice = allocator.alloc(ptr.child, value.len) catch
                        @panic("deepCopy: allocation failed");
                    for (new_slice, value) |*destination, source| {
                        destination.* = deepCopy(ptr.child, source, allocator);
                    }
                    return new_slice;
                },
                else => @compileError("deepCopy does not support non-slice pointer: " ++ @typeName(T)),
            }
        },
        .optional => |optional| {
            if (value) |unwrapped| {
                return deepCopy(optional.child, unwrapped, allocator);
            } else {
                return null;
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type) |_| {
                // Tagged union: switch on the active field and deep-copy its payload
                return switch (value) {
                    inline else => |payload, tag| {
                        const field_info = union_info.fields[@intFromEnum(tag)];
                        if (field_info.type == void) {
                            return @unionInit(T, field_info.name, {});
                        } else {
                            return @unionInit(T, field_info.name, deepCopy(field_info.type, payload, allocator));
                        }
                    },
                };
            } else {
                @compileError("deepCopy does not support untagged unions: " ++ @typeName(T));
            }
        },
        .@"struct" => |struct_info| {
            var result: T = undefined;
            inline for (struct_info.fields) |field| {
                @field(result, field.name) = deepCopy(field.type, @field(value, field.name), allocator);
            }
            return result;
        },
        .@"enum", .int, .comptime_int, .float, .comptime_float, .bool, .void => {
            return value;
        },
        .array => |array_info| {
            var result: T = undefined;
            for (&result, value) |*destination, source| {
                destination.* = deepCopy(array_info.child, source, allocator);
            }
            return result;
        },
        else => @compileError("deepCopy does not support type: " ++ @typeName(T)),
    }
}

/// Generic structural equality, the inverse companion to `deepCopy`. Mirrors
/// the same comptime-reflection cases so it tracks new fields automatically.
/// No floats are compared (event payloads are ints/enums/bools/strings/
/// slices/structs), so exact `==` is correct everywhere it applies.
///
/// Used by replay verification (see `GameStateHistory.verifyReplayMatch`) to
/// confirm the event the handlers would run next equals the recorded one.
pub fn deepEqual(comptime T: type, a: T, b: T) bool {
    const info = @typeInfo(T);

    switch (info) {
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (a.len != b.len) return false;
                    for (a, b) |x, y| {
                        if (!deepEqual(ptr.child, x, y)) return false;
                    }
                    return true;
                },
                else => @compileError("deepEqual does not support non-slice pointer: " ++ @typeName(T)),
            }
        },
        .optional => |optional| {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            return deepEqual(optional.child, a.?, b.?);
        },
        .@"union" => |union_info| {
            if (union_info.tag_type != null) {
                const a_tag = std.meta.activeTag(a);
                const b_tag = std.meta.activeTag(b);
                if (a_tag != b_tag) return false;
                return switch (a) {
                    inline else => |payload, tag| blk: {
                        const field_info = union_info.fields[@intFromEnum(tag)];
                        if (field_info.type == void) break :blk true;
                        break :blk deepEqual(field_info.type, payload, @field(b, field_info.name));
                    },
                };
            } else {
                @compileError("deepEqual does not support untagged unions: " ++ @typeName(T));
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (!deepEqual(field.type, @field(a, field.name), @field(b, field.name))) return false;
            }
            return true;
        },
        .@"enum", .int, .comptime_int, .float, .comptime_float, .bool, .void => {
            return a == b;
        },
        .array => |array_info| {
            for (a, b) |x, y| {
                if (!deepEqual(array_info.child, x, y)) return false;
            }
            return true;
        },
        else => @compileError("deepEqual does not support type: " ++ @typeName(T)),
    }
}

/// Name the first field (by declaration order) where `a` and `b` differ
/// structurally, or null if they are `deepEqual` (or if the difference is a
/// union tag mismatch, which is self-evident from the tag names in the panic
/// message). Used to make replay-verification panics point at the offending
/// payload field. Recurses into tagged-union payloads so it works on the
/// `Event` union itself. For scalar/leaf types that simply differ, returns
/// "" (empty). The returned name is a comptime `field.name`, so no allocation
/// is needed.
pub fn firstDiffField(comptime T: type, a: T, b: T) ?[:0]const u8 {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                if (!deepEqual(field.type, @field(a, field.name), @field(b, field.name))) {
                    return field.name;
                }
            }
            return null;
        },
        .@"union" => |union_info| {
            if (union_info.tag_type) |_| {
                const a_tag = std.meta.activeTag(a);
                const b_tag = std.meta.activeTag(b);
                if (a_tag != b_tag) return null;
                return switch (a) {
                    inline else => |payload, tag| blk: {
                        const field_info = union_info.fields[@intFromEnum(tag)];
                        if (field_info.type == void) break :blk null;
                        break :blk firstDiffField(field_info.type, payload, @field(b, field_info.name));
                    },
                };
            } else {
                @compileError("firstDiffField does not support untagged unions: " ++ @typeName(T));
            }
        },
        else => {
            if (!deepEqual(T, a, b)) return "";
            return null;
        },
    }
}

// --- tests for deepEqual / firstDiffField (the replay-verification core) ---

const Vec = struct { x: i32, y: i32 };
const Leaf = union(enum) { a: i32, b: Vec, none: void };
const Node = struct {
    name: []const u8,
    pos: Vec,
    tag: Leaf,
    opt: ?i32,
};

test "deepEqual: identical structs are equal" {
    const x = Node{ .name = "p", .pos = .{ .x = 1, .y = 2 }, .tag = .{ .a = 5 }, .opt = null };
    const y = Node{ .name = "p", .pos = .{ .x = 1, .y = 2 }, .tag = .{ .a = 5 }, .opt = null };
    try std.testing.expect(deepEqual(Node, x, y));
    try std.testing.expectEqual(@as(?[:0]const u8, null), firstDiffField(Node, x, y));
}

test "deepEqual: scalar field difference detected + named" {
    const x = Node{ .name = "p", .pos = .{ .x = 1, .y = 2 }, .tag = .{ .a = 5 }, .opt = null };
    const y = Node{ .name = "p", .pos = .{ .x = 9, .y = 2 }, .tag = .{ .a = 5 }, .opt = null };
    try std.testing.expect(!deepEqual(Node, x, y));
    try std.testing.expectEqualStrings("pos", firstDiffField(Node, x, y).?);
}

test "deepEqual: slice length + element differences detected" {
    const a: []const i32 = &.{ 1, 2, 3 };
    const b: []const i32 = &.{ 1, 2 };
    try std.testing.expect(!deepEqual([]const i32, a, b));
    const c: []const i32 = &.{ 1, 9, 3 };
    try std.testing.expect(!deepEqual([]const i32, a, c));
    try std.testing.expect(deepEqual([]const i32, a, a));
}

test "deepEqual: optional null vs value" {
    const x = Node{ .name = "p", .pos = .{ .x = 1, .y = 2 }, .tag = .{ .a = 5 }, .opt = null };
    const y = Node{ .name = "p", .pos = .{ .x = 1, .y = 2 }, .tag = .{ .a = 5 }, .opt = 7 };
    try std.testing.expect(!deepEqual(Node, x, y));
    try std.testing.expectEqualStrings("opt", firstDiffField(Node, x, y).?);
}

test "deepEqual: union tag mismatch" {
    const x = Node{ .name = "p", .pos = .{ .x = 1, .y = 2 }, .tag = .{ .a = 5 }, .opt = null };
    const y = Node{ .name = "p", .pos = .{ .x = 1, .y = 2 }, .tag = .{ .b = .{ .x = 1, .y = 2 } }, .opt = null };
    try std.testing.expect(!deepEqual(Node, x, y));
    // On a struct, the first differing field is named - here `tag`.
    try std.testing.expectEqualStrings("tag", firstDiffField(Node, x, y).?);
    // On the union directly, a tag mismatch yields null (names already differ).
    try std.testing.expectEqual(@as(?[:0]const u8, null), firstDiffField(Leaf, x.tag, y.tag));
}

test "deepEqual: union payload field mismatch named through recursion" {
    const a: Leaf = .{ .b = .{ .x = 1, .y = 2 } };
    const b: Leaf = .{ .b = .{ .x = 1, .y = 9 } };
    try std.testing.expect(!deepEqual(Leaf, a, b));
    // firstDiffField recurses into the active union payload's struct fields.
    try std.testing.expectEqualStrings("y", firstDiffField(Leaf, a, b).?);
}
