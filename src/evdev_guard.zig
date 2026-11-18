//! Pure classification helpers for the evdev joystick-claim guard: deciding
//! which /dev/input/event* nodes are safe for the native build's bundled
//! GLFW to claim as joysticks. Raylib-free + syscall-free so the test build
//! runs it headless; the interposed `open` that ACTS on this classification
//! lives at the platform seam in src/raylib/evdev_guard.zig. Design +
//! rationale (the bundled-GLFW OOB crash this exists to prevent):
//! DESIGN → Platform Seam → Evdev joystick-claim guard.

const std = @import("std");

/// Linux input-event constants (linux/input-event-codes.h). KEY_CNT is
/// KEY_MAX (0x2ff) + 1 = 768 - the kernel key bitfield is KEY_CNT/8 bytes.
pub const KEY_CNT: u16 = 768;
pub const key_bits_len: usize = KEY_CNT / 8;

/// EV_KEY event TYPE (input-event-codes.h: EV_SYN=0, EV_KEY=1, ...).
/// Note the namespace trap: 0x21 is a key CODE (KEY_MUTE), not the type;
/// the event-bit query below uses the type.
pub const EV_KEY: u8 = 0x01;

/// Key-code ranges that mark a device as a real joystick/gamepad: BTN_JOYSTICK
/// (0x120) through the BTN_GAMEPAD buttons (up to 0x13f), plus BTN_TRIGGER_HAPPY
/// 1..40 (0x2c0..0x2e7). SDL applies the same "needs gamepad-class buttons"
/// idea when it filters evdev nodes.
const joystick_ranges = [_][2]u16{
    .{ 0x120, 0x13f }, // BTN_JOYSTICK .. BTN_GAMEPAD button range
    .{ 0x2c0, 0x2e7 }, // BTN_TRIGGER_HAPPY1 .. BTN_TRIGGER_HAPPY40
};

pub fn testBit(
    bits: *const [key_bits_len]u8,
    code: u16,
) bool {
    return bits[code / 8] & (@as(u8, 1) << @intCast(code % 8)) != 0;
}

/// The check bundled GLFW's openJoystickDevice should have applied but did
/// not (it claims ANY device with EV_ABS, then indexes keyMap[code - BTN_MISC]
/// unguarded for every EV_KEY event - codes below BTN_MISC go negative).
///
/// A device classifies as a joystick only if EVERY set key bit lies inside
/// a joystick button range, and at least one is present. Two disqualifiers:
/// - Any code below BTN_JOYSTICK (keyboard keys, consumer-control codes
///   like KEY_MUTE, mouse buttons) - the crash class: such devices are
///   claimed via their EV_ABS (ABS_VOLUME) but their low codes index
///   keyMap negative. This also rejects hybrid "gamepad + media keys"
///   boards, which would otherwise still carry the latent crash.
/// - Digitizer/tool buttons (BTN_TOOL_*, BTN_TOUCH, ...) without any
///   gamepad-class button - touchscreens and pens expose EV_ABS too.
pub fn classifiesAsJoystick(
    key_bits: *const [key_bits_len]u8,
) bool {
    var has_joystick_button = false;
    for (0..KEY_CNT) |code| {
        const code_u16: u16 = @intCast(code);
        if (!testBit(key_bits, code_u16)) continue;
        if (inJoystickRange(code_u16)) {
            has_joystick_button = true;
        } else {
            return false;
        }
    }
    return has_joystick_button;
}

fn inJoystickRange(code: u16) bool {
    inline for (joystick_ranges) |range| {
        if (code >= range[0] and code <= range[1]) return true;
    }
    return false;
}

/// EVIOCGBIT(ev, len) exactly as the kernel's uapi macro computes it
/// (linux/input.h: _IOC(_IOC_READ, 'E', 0x20 + ev, len), asm-generic ioctl
/// encoding: read direction (2 << 30), 14-bit size, 8-bit type 'E',
/// nr 0x20 + ev). Both x86_64 and aarch64 Linux use this encoding; the
/// pinned-value test guards against drift in the hand-rolled arithmetic
/// (a wrong constant fails the runtime ioctl and the guard would reject
/// every device - the exact failure the empirical A/B run caught).
pub fn eviocgbit(
    ev: u8,
    len: usize,
) u32 {
    return @as(u32, 2) << 30 |
        @as(u32, @intCast(len)) << 16 |
        @as(u32, 'E') << 8 |
        (0x20 + @as(u32, ev));
}

/// The path class GLFW claims joysticks from: /dev/input/event<digits>
/// (its inotify regex is "^event[0-9]+$"). The guard intercepts exactly
/// this class and lets every other open pass through untouched.
pub fn isInputEventNodePath(path: []const u8) bool {
    const prefix = "/dev/input/event";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const digits = path[prefix.len..];
    if (digits.len == 0) return false;
    for (digits) |character| {
        if (character < '0' or character > '9') return false;
    }
    return true;
}

test "EVIOCGBIT command matches the kernel macro expansion" {
    // _IOC(_IOC_READ, 'E', 0x20 + EV_KEY, 96): dir 2, type 'E', nr 0x21,
    // size 96 - the exact value a C program with the system headers emits
    // (verified against /usr/include/linux/input.h + a compiled probe).
    try std.testing.expectEqual(@as(u32, 0x80604521), eviocgbit(EV_KEY, key_bits_len));
}

test "consumer-control media-key device is not a joystick" {
    // The CP24 / Wooting consumer-control class: EV_ABS (ABS_VOLUME) +
    // low key codes. KEY_MUTE = 113, KEY_VOLUMEUP = 115, KEY_PLAYPAUSE = 164.
    var key_bits: [key_bits_len]u8 = @splat(0);
    key_bits[113 / 8] |= @as(u8, 1) << @intCast(113 % 8);
    key_bits[115 / 8] |= @as(u8, 1) << @intCast(115 % 8);
    key_bits[164 / 8] |= @as(u8, 1) << @intCast(164 % 8);
    try std.testing.expect(!classifiesAsJoystick(&key_bits));
}

test "plain keyboard keys are not a joystick" {
    // KEY_A = 30, KEY_ENTER = 28, arrow keys = 103..106.
    var key_bits: [key_bits_len]u8 = @splat(0);
    key_bits[30 / 8] |= @as(u8, 1) << @intCast(30 % 8);
    key_bits[103 / 8] |= @as(u8, 1) << @intCast(103 % 8);
    try std.testing.expect(!classifiesAsJoystick(&key_bits));
}

test "gamepad and joystick buttons classify as a joystick" {
    // BTN_SOUTH (0x130) + BTN_THUMBL (0x13d) + BTN_TRIGGER (0x120) +
    // BTN_TRIGGER_HAPPY1 (0x2c0).
    var key_bits: [key_bits_len]u8 = @splat(0);
    for ([_]u16{ 0x130, 0x13d, 0x120, 0x2c0 }) |code| {
        key_bits[code / 8] |= @as(u8, 1) << @intCast(code % 8);
    }
    try std.testing.expect(classifiesAsJoystick(&key_bits));
}

test "hybrid gamepad + media keys is rejected" {
    // A board with gamepad buttons AND consumer keys would be a legitimate
    // gamepad for reading state - but claiming it re-arms the unguarded
    // keyMap index for its low codes, so the guard rejects it.
    var key_bits: [key_bits_len]u8 = @splat(0);
    key_bits[0x130 / 8] |= @as(u8, 1) << @intCast(0x130 % 8);
    key_bits[113 / 8] |= @as(u8, 1) << @intCast(113 % 8);
    try std.testing.expect(!classifiesAsJoystick(&key_bits));
}

test "touchscreen digitizer buttons are not a joystick" {
    // BTN_TOOL_PEN (0x140), BTN_TOUCH (0x14a), BTN_STYLUS (0x145) - devices
    // with EV_ABS that GLFW wrongly claims; no gamepad-class button present.
    var key_bits: [key_bits_len]u8 = @splat(0);
    for ([_]u16{ 0x140, 0x14a, 0x145 }) |code| {
        key_bits[code / 8] |= @as(u8, 1) << @intCast(code % 8);
    }
    try std.testing.expect(!classifiesAsJoystick(&key_bits));
}

test "an empty key bitfield is not a joystick" {
    // EV_ABS with no key bits at all (e.g. an accelerometer): claimed by
    // GLFW today, rejected by the guard - no buttons means nothing to read.
    const key_bits: [key_bits_len]u8 = @splat(0);
    try std.testing.expect(!classifiesAsJoystick(&key_bits));
}

test "an all-bits-set bitfield is not a joystick" {
    // Worst case garbage: contains every low key code, so rejected by the
    // any-non-joystick-code disqualifier rather than misclassifying.
    const key_bits: [key_bits_len]u8 = @splat(0xff);
    try std.testing.expect(!classifiesAsJoystick(&key_bits));
}

test "path matching mirrors the event-node class GLFW claims" {
    try std.testing.expect(isInputEventNodePath("/dev/input/event0"));
    try std.testing.expect(isInputEventNodePath("/dev/input/event112"));
    try std.testing.expect(!isInputEventNodePath("/dev/input/event"));
    try std.testing.expect(!isInputEventNodePath("/dev/input/event10x"));
    try std.testing.expect(!isInputEventNodePath("/dev/input/mice"));
    try std.testing.expect(!isInputEventNodePath("/dev/input/by-id/foo"));
    try std.testing.expect(!isInputEventNodePath("/home/user/event3"));
    // The classic joydev nodes are not in GLFW's claim class.
    try std.testing.expect(!isInputEventNodePath("/dev/input/js0"));
}
