//! Native (desktop) entry point. Root source of the native exe. This is one of
//! the two files that compile against raylib (via raylib_backend.zig); the
//! shared game logic in main.zig stays raylib-free. It sets up the allocator,
//! IO, and raylib window, then hands control to main.run with a RaylibBackend.

const std = @import("std");
const game = @import("main.zig");
const RaylibBackend = @import("raylib_backend.zig").RaylibBackend;
const types = @import("types.zig");

pub fn main() void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const directory = std.Io.Dir.cwd();

    // Open at half the reference resolution; the window is resizable and the
    // renderer scales reference-space content to the actual viewport.
    var backend = RaylibBackend.init(
        allocator,
        @divTrunc(types.reference_width, 2),
        @divTrunc(types.reference_height, 2),
        "Ziglop",
    );
    defer backend.deinit();

    game.run(&backend, allocator, directory, io);
}
