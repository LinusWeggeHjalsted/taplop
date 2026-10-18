//! Pure easing functions for one-shot animations. No state, no allocators,
//! no I/O - just `fn(f32) f32` taking a normalized progress `t` in [0, 1]
//! and returning an eased progress. `view()` computes
//! `progress = (animation_clock - start_clock) / duration`, clamps to [0, 1],
//! and applies an easing fn before interpolating position. Replay-safe by
//! construction: pure, rendering-side, reads the pause-gated clock. See
//! DESIGN → Animation.

const std = @import("std");

/// Ease-out cubic: starts fast, decelerates to a stop. `1 - (1 - t)^3`.
/// Fast at the start and slowing near the end - the "snappy" feel requested
/// for damage-number float. At t=0 → 0, t=1 → 1, monotonic.
pub fn easeOutCubic(t: f32) f32 {
    const u = 1.0 - t;
    return 1.0 - u * u * u;
}

test "easeOutCubic endpoints and monotonicity" {
    try std.testing.expectApproxEqAbs(easeOutCubic(0.0), 0.0, 1e-6);
    try std.testing.expectApproxEqAbs(easeOutCubic(1.0), 1.0, 1e-6);
    // Monotonic non-decreasing over [0, 1].
    var i: u32 = 0;
    var prev: f32 = -1.0;
    while (i <= 100) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / 100.0;
        const e = easeOutCubic(t);
        try std.testing.expect(e >= prev);
        prev = e;
    }
}

test "easeOutCubic is front-loaded (fast then slow)" {
    // At the midpoint the eased value should exceed 0.5 (front-loaded: more
    // of the travel happens early). easeOutCubic(0.5) = 1 - 0.125 = 0.875.
    try std.testing.expectApproxEqAbs(easeOutCubic(0.5), 0.875, 1e-6);
    try std.testing.expect(easeOutCubic(0.5) > 0.5);
}
