//! Link-time interposition of `open` for the native Linux build - the fix
//! for the bundled-GLFW joystick crash (TODO → Platform Layer → NATIVE
//! CRASH; settled design: DESIGN → Platform Seam → Evdev joystick-claim
//! guard). GLFW's openJoystickDevice claims ANY /dev/input/event* node with
//! EV_ABS (consumer-control interfaces qualify via ABS_VOLUME), then
//! handleKeyEvent indexes keyMap[code - BTN_MISC] unguarded, so a KEY_MUTE
//! (113) press from such a device traps under UBSan (and is an OOB write
//! in release). Rather than patching the vendored C, this file defines the
//! libc `open`/`open64` symbols in OUR executable: the statically linked
//! raylib objects resolve their `open` call sites against these
//! definitions (ELF interposition - an exe-defined symbol preempts the
//! shared libc's for the exe's own references). Every open that is not a
//! /dev/input/event* node passes straight through via a raw openat
//! syscall (no libc call, so no recursion). For event nodes the guard
//! first applies the classification GLFW should have applied (see
//! src/evdev_guard.zig): a device without gamepad-class buttons - or with
//! ANY non-joystick key code - gets ENODEV, and openJoystickDevice's
//! open-failure path silently skips it. The crash is unreachable, in
//! Debug and Release alike; real gamepads classify through. Comptime-gated
//! to Linux (web is wasm; macOS has no evdev), so the file compiles empty
//! elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const evdev = @import("../evdev_guard.zig");

const guard = if (builtin.os.tag == .linux) struct {
    const linux = std.os.linux;

    /// libc's open is variadic (mode is the optional third arg); Zig cannot
    /// define C-variadic functions, so these export the fixed 3-arg shape.
    /// ABI-compatible: SysV passes the leading args in registers either
    /// way, the mode register is only meaningful when the caller set
    /// O_CREAT (and is then always passed), and the varargs ABI state is
    /// callee-ignored. `open64` is glibc's LFS alias for `open` on 64-bit.
    export fn open(
        path: [*:0]const u8,
        flags: c_int,
        mode: c_int,
    ) c_int {
        return openGuarded(path, @as(u32, @bitCast(flags)), @as(u32, @bitCast(mode)));
    }

    export fn open64(
        path: [*:0]const u8,
        flags: c_int,
        mode: c_int,
    ) c_int {
        return openGuarded(path, @as(u32, @bitCast(flags)), @as(u32, @bitCast(mode)));
    }

    fn openGuarded(
        path: [*:0]const u8,
        flags: u32,
        mode: u32,
    ) c_int {
        if (evdev.isInputEventNodePath(std.mem.span(path))) {
            if (!claimsAsSafeJoystick(path)) {
                // openJoystickDevice treats an open failure as "skip this
                // device" - no error, no claim, the buggy path is never
                // armed for this device.
                setErrno(.NODEV);
                return -1;
            }
        }
        return rawOpen(path, flags, mode);
    }

    /// The passthrough open: a raw openat syscall against AT_FDCWD, never
    /// a libc call, so the interposed symbol cannot recurse into itself.
    fn rawOpen(
        path: [*:0]const u8,
        flags: u32,
        mode: u32,
    ) c_int {
        const result_code = linux.syscall4(
            .openat,
            @as(usize, @bitCast(@as(isize, linux.AT.FDCWD))),
            @intFromPtr(path),
            flags,
            mode,
        );
        const errno = linux.errno(result_code);
        if (errno != .SUCCESS) {
            setErrno(errno);
            return -1;
        }
        return @intCast(result_code);
    }

    fn setErrno(errno: linux.E) void {
        std.c._errno().* = @intCast(@backingInt(errno));
    }

    /// Query the device's key bitfield (the same EVIOCGBIT GLFW's claim
    /// path uses) and classify it. Read-only capability queries - this
    /// never writes events into the node. Fails closed: if the probe open
    /// or ioctl fails for any reason, the device is not claimed.
    fn claimsAsSafeJoystick(path: [*:0]const u8) bool {
        const probe_flags: u32 = @bitCast(linux.O{
            .NONBLOCK = true,
            .CLOEXEC = true,
        });
        const probe_fd = rawOpen(path, probe_flags, 0);
        if (probe_fd < 0) return false;
        defer _ = linux.syscall1(.close, @intCast(probe_fd));

        var key_bits: [evdev.key_bits_len]u8 = undefined;
        const request = evdev.eviocgbit(evdev.EV_KEY, evdev.key_bits_len);
        const ioctl_result = linux.syscall3(
            .ioctl,
            @intCast(probe_fd),
            request,
            @intFromPtr(&key_bits),
        );
        if (linux.errno(ioctl_result) != .SUCCESS) return false;

        return evdev.classifiesAsJoystick(&key_bits);
    }
} else struct {};

comptime {
    _ = guard;
}
