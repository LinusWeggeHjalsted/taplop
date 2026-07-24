const std = @import("std");

/// Generic deep copy: recursively clones any value into an arena allocator.
/// - Slices are duplicated (elements deep-copied if they contain slices/pointers)
/// - Optionals are unwrapped and deep-copied if non-null
/// - Tagged unions have their active field deep-copied
/// - Structs have each field deep-copied
/// - Scalars, enums, bools, ints, floats pass through unchanged
///
/// Because this uses comptime reflection, it automatically handles new fields
/// added to any struct — no manual updating needed.
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
        .optional => |opt| {
            if (value) |v| {
                return deepCopy(opt.child, v, allocator);
            } else {
                return null;
            }
        },
        .@"union" => |u| {
            if (u.tag_type) |_| {
                // Tagged union: switch on the active field and deep-copy its payload
                return switch (value) {
                    inline else => |payload, tag| {
                        const field_info = u.fields[@intFromEnum(tag)];
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
        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.fields) |field| {
                @field(result, field.name) = deepCopy(field.type, @field(value, field.name), allocator);
            }
            return result;
        },
        .@"enum", .int, .comptime_int, .float, .comptime_float, .bool, .void => {
            return value;
        },
        .array => |arr| {
            var result: T = undefined;
            for (&result, value) |*destination, source| {
                destination.* = deepCopy(arr.child, source, allocator);
            }
            return result;
        },
        else => @compileError("deepCopy does not support type: " ++ @typeName(T)),
    }
}
