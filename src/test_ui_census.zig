//! Shared census helpers for ui builder tests - the exhaustiveness shape
//! of DESIGN → Testing → Assertion patterns: the panel under test is built
//! at EVERY scroll offset 0..clamped max, so geometry is the INPUT to the
//! test, never the expectation. A pinned window ("at scroll 14 exactly
//! these labels") churns on every layout change; the exhaustive census
//! asserts the structural properties that layout changes preserve.
//!
//! Panels duck-type one method:
//!   fn buildAt(self, scroll: i32, elements: *UiElementList) anyerror!i32
//! building the panel at a scroll offset and returning the CLAMPED offset
//! (the builder's own clamp - a probe with maxInt yields the max).

const std = @import("std");
const element_mod = @import("ui/element.zig");

const UiElementList = element_mod.UiElementList;

/// The exhaustive label census: over every scroll offset, (1) each
/// window's labels must be an ordered subset of `expected_content` (the
/// panel's full semantic content list, duplicates included - the contract
/// the builder must emit, NOT a window snapshot), and (2) the union of all
/// windows must cover the list completely - no never-emitted row, no
/// unreachable row. Mismatches print found-vs-expected.
pub fn expectContentReachable(
    allocator: std.mem.Allocator,
    panel: anytype,
    expected_content: []const []const u8,
) !void {
    const max_scroll = try maxScroll(panel);

    const seen = try allocator.alloc(bool, expected_content.len);
    defer allocator.free(seen);
    @memset(seen, false);

    var scroll: i32 = 0;
    while (scroll <= max_scroll) : (scroll += 1) {
        var elements: UiElementList = .empty;
        _ = try panel.buildAt(scroll, &elements);
        var next: usize = 0;
        for (elements.items) |element| switch (element) {
            .text_label => |label| {
                const index = orderedIndexOf(expected_content, label.text, next) orelse {
                    std.debug.print(
                        "census: unexpected label '{s}' at scroll {d} - not in the expected content list, or out of order\n",
                        .{ label.text, scroll },
                    );
                    printContentList(expected_content);
                    return error.CensusUnexpectedLabel;
                };
                seen[index] = true;
                next = index + 1;
            },
            else => {},
        };
    }

    var missing: usize = 0;
    for (seen) |entry_seen| {
        if (!entry_seen) missing += 1;
    }
    if (missing > 0) {
        std.debug.print("census: {d} expected content entries never visible:\n", .{missing});
        for (expected_content, seen) |entry, entry_seen| {
            if (!entry_seen) std.debug.print("  {s}\n", .{entry});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

/// The panel's clamped max scroll (a probe build with a huge offset; the
/// builder's clamp does the work).
pub fn maxScroll(panel: anytype) !i32 {
    var probe: UiElementList = .empty;
    return panel.buildAt(std.math.maxInt(i32), &probe);
}

fn orderedIndexOf(entries: []const []const u8, text: []const u8, from: usize) ?usize {
    var index = from;
    while (index < entries.len) : (index += 1) {
        if (std.mem.eql(u8, entries[index], text)) return index;
    }
    return null;
}

fn printContentList(expected_content: []const []const u8) void {
    std.debug.print("expected content:", .{});
    for (expected_content) |entry| std.debug.print(" {s}", .{entry});
    std.debug.print("\n", .{});
}
