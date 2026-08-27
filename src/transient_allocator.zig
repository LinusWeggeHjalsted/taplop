//! Allocator for untracked, throwaway allocations (transient buffers that
//! outlive arenas: font bytes, crash-dump output, existence probes).
//!
//! WHY not `std.heap.page_allocator` everywhere: on wasm32-emscripten,
//! page_allocator is BrkAllocator, which grows wasm memory via the RAW
//! `@wasmMemoryGrow` intrinsic. Emscripten's JS glue only refreshes its heap
//! views (HEAP8/HEAPU8...) and SAFE_HEAP bounds when growth goes through ITS
//! allocator (emmalloc's sbrk → emscripten_resize_heap). A raw grow therefore
//! leaves the JS side stale: the views detach (any JS access to wasm memory,
//! e.g. fd_write during a print, aborts) and SAFE_HEAP keeps the old memory
//! size (any wasm access to the freshly grown region reports a segfault).
//! Verified empirically: a single `page_allocator.alloc` on the web build
//! segfaults on first access. Rule: on emscripten, ALL allocations go through
//! libc (emmalloc) so memory growth updates the JS glue.

const std = @import("std");

/// The transient allocator. Native: page_allocator (no DebugAllocator
/// tracking — these buffers are deliberately untracked and short-lived).
/// Emscripten: c_allocator (emmalloc — see the file-level comment).
pub const allocator: std.mem.Allocator = if (@import("builtin").os.tag == .emscripten)
    std.heap.c_allocator
else
    std.heap.page_allocator;
