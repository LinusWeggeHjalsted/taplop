//! Session startup: loading all config (settings, color themes, weapon types,
//! salvage tables) and assembling the session-long `SessionSetup` (config
//! definitions + `FrameState`) that both platform drivers consume. The entry
//! files (`native.zig`/`web.zig`) call `createSessionSetup` then hand the
//! result to `main.run`/`main.frame`. `FrameState` lives here (not `main.zig`)
//! so this module is a leaf: `main → session_setup`, never the reverse.
//! See DESIGN → File System & IO, Platform Seam, Error Handling.

const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const input = @import("input.zig");
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const writers = @import("writers.zig");
const file_source_mod = @import("file_source.zig");
const console = @import("console.zig");

const FileSource = file_source_mod.FileSource;
const GameState = state.GameState;
const GameStateHistory = state.GameStateHistory;
const Settings = types.Settings;
const WeaponType = types.WeaponType;
const WeaponTypeDefinition = types.WeaponTypeDefinition;
const ColorThemeDefinitions = types.ColorThemeDefinitions;

pub const weapon_type_count = @typeInfo(WeaponType).@"enum".fields.len;

/// Per-session mutable state that lives across frames, held by the platform
/// driver. `history` is the undo/replay timeline; `previous_view_state` is the
/// last rendered view (input resolves screen→tile against it); `frame_arena`
/// is reset each render; `last_render_time` gates rendering to a real-clock
/// interval.
pub const FrameState = struct {
    history: GameStateHistory,
    previous_view_state: ?types.ViewState = null,
    /// Per-frame arena: everything a ViewState points at is allocated here and
    /// reset (retaining capacity) at the start of the next render.
    frame_arena: std.heap.ArenaAllocator,
    /// Last render time (real-clock microseconds) for the render-interval gate.
    last_render_time: u64,
    /// The console input queue (stdin - see DESIGN → Input → Console input).
    /// Empty without a reader thread (web, or a native launch without stdin,
    /// which is immediate EOF); the native driver spawns the reader and wires
    /// the dump output writer.
    console_queue: console.ConsoleQueue = .{},
    /// The previous frame's translated input + real-clock delta - the
    /// observability stash (see DESIGN → Input → Console input → dump
    /// paths): written once per frame in `main.frame` right after
    /// translateInput + the console action fold, read by `dump
    /// previous_player_input...` / `dump previous_delta_microseconds`.
    /// Null before the first frame. The `previous_` naming follows
    /// previous_view_state ("what was true last frame is what you act
    /// against this frame") - and a dump executed on frame N+1 shows
    /// frame N's translation, so `press X` followed by `dump
    /// previous_player_input...` asserts what the press DID.
    /// Plain wholesale copy - PlayerInput is all values except one string
    /// payload, and that payload (clicked_payload's editor_sprite variant) borrows
    /// session-owned scan bytes (MissionSprite.stored_id), so nothing in
    /// the stash can dangle into the reset frame arena.
    previous_player_input: ?input.PlayerInput = null,
    /// The previous frame's real-clock delta - the timing fact the stash
    /// exists for (before it, the frame period had to be measured by
    /// timing whole process runs against each other).
    previous_delta_microseconds: u64 = 0,
};

/// Collected startup warnings (one per config file that fell back to its
/// embedded copy, or per stale entry the overlay repaired). Passed by-
/// mutable-pointer to each loader as `&startup.warnings` (the list lives on
/// `StartupMemory`); the helper appends to it. `createSessionSetup`
/// concatenates the entries into a single `pending_error` after the
/// history is created (the popup lives on SessionState, which is on
/// GameStateHistory). The warning strings are backing-allocator-owned,
/// tracked in the SessionSetup's StartupMemory, and freed by
/// `freeSessionSetup` (the web re-boot's teardown) - process-lifetime on
/// native. See DESIGN → Error Handling → three contexts.
const Warnings = *std.ArrayList([]const u8);

/// One retained startup allocation: the raw config bytes + the parsed
/// sections of one load attempt the session KEEPS. The loaded values own
/// their own strings/slices (duped by the loaders), but the bytes +
/// section containers stay referenced for the session (the values' fields
/// can borrow from section strings), so they are tracked here and freed by
/// `freeSessionSetup` - AFTER the history deinit freed the loaded values
/// (values first, then section containers, then bytes).
pub const StartupAllocation = struct {
    config_bytes: []const u8,
    sections: []const parser.Section,
};

/// Tracked startup memory (the teardown's bookkeeping): every retained
/// bytes + sections pair plus the startup warning strings. Production
/// never frees it (process lifetime - native never tears down); the web
/// re-boot's teardown (`freeSessionSetup`) frees it all so a re-booted
/// session doesn't leak the previous session's startup memory on every
/// Import Game. Owned by `SessionSetup` (filled by `createSessionSetup`
/// through the loaders below; the lists' own memory is backing-allocated).
pub const StartupMemory = struct {
    allocations: std.ArrayList(StartupAllocation) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,

    /// Track a retained bytes + sections pair (freed by freeSessionSetup).
    fn retain(
        self: *StartupMemory,
        allocator: std.mem.Allocator,
        config_bytes: []const u8,
        sections: []const parser.Section,
    ) void {
        self.allocations.append(allocator, .{ .config_bytes = config_bytes, .sections = sections }) catch
            @panic("failed to track startup allocation");
    }
};

/// Read + parse a config file and load it via `load_fn`, falling back to the
/// embedded copy if the first attempt (persistent-dir shadow → embedded) fails
/// at any stage - read, parse, or `load_fn`. On a successful first attempt,
/// returns the loaded value with no warning. On a failed first attempt +
/// successful embedded retry, appends a warning to `startup.warnings` and
/// returns the value. If the embedded copy also fails, panics - shipped
/// content is broken, a real bug. See DESIGN → Error Handling → three
/// contexts.
///
/// `load_fn` has shape `fn ([]const parser.Section, std.mem.Allocator) anyerror!T`
/// (the common loader shape; `loadWeaponTypeDefinition` is wrapped to match).
/// The bytes + sections of every RETAINED attempt (a successful load, or a
/// load_fn failure that falls through to the retry) are tracked in
/// `startup` - process-lifetime on native, freed by the web re-boot's
/// teardown (`freeSessionSetup`) via the same tracking.
fn loadConfigWithFallback(
    comptime T: type,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    path: []const u8,
    load_fn: *const fn ([]const parser.Section, std.mem.Allocator) anyerror!T,
    key_map: std.StaticStringMap([]const []const u8),
    startup: *StartupMemory,
) T {
    const warnings = &startup.warnings;
    // First attempt: normal read order (persistent dir → embedded).
    if (file_source.readFile(allocator, path)) |bytes| {
        if (parser.parseConfigFile(bytes, allocator)) |sections| {
            if (load_fn(sections, allocator)) |result| {
                parser.validateKeys(sections, key_map, path, allocator, warnings);
                startup.retain(allocator, bytes, sections);
                return result;
            } else |_| {
                // A load_fn failure falls through to the embedded retry with
                // the attempt's bytes + sections retained (tracked - freed
                // by the teardown; a failed load_fn may have left partial
                // allocations that cannot be named here).
                startup.retain(allocator, bytes, sections);
            }
        } else |_| {
            allocator.free(bytes);
        }
    } else |_| {}

    // Fallback: embedded copy only (skip the persistent-dir shadow).
    const embedded_bytes = file_source.readEmbeddedFile(allocator, path) catch
        @panic("startup config file missing from embedded map");
    const sections = parser.parseConfigFile(embedded_bytes, allocator) catch
        @panic("failed to parse embedded startup config file");
    const result = load_fn(sections, allocator) catch
        @panic("failed to load embedded startup config file");
    // Validate the embedded copy too - an unknown key in a parsing-OK
    // embedded file is a softer issue worth surfacing (the panic above
    // fires first on a parse/load failure).
    parser.validateKeys(sections, key_map, path, allocator, warnings);
    startup.retain(allocator, embedded_bytes, sections);

    warnings.append(allocator, std.fmt.allocPrint(allocator, "Failed to parse {s}; using built-in default.", .{path}) catch
        @panic("failed to allocate startup warning")) catch
        @panic("failed to append startup warning");
    return result;
}

/// Wrapper so `loadConfigWithFallback` can call `loadWeaponTypeDefinition`,
/// which takes only sections (no allocator), through the common
/// `(sections, allocator)` shape.
fn loadWeaponTypeDefinitionWrapped(
    sections: []const parser.Section,
    _: std.mem.Allocator,
) !WeaponTypeDefinition {
    return loaders.loadWeaponTypeDefinition(sections);
}

/// Wrapper so `loadConfigWithFallback` can call `loaders.loadSettings` through
/// the common 2-param `(sections, allocator)` interface (loadSettings takes an
/// extra `base` param for the user-overlay path).
fn loadSettingsWrapped(
    sections: []const parser.Section,
    allocator: std.mem.Allocator,
) anyerror!Settings {
    // Null warnings: the shipped defaults file is round-trip-tested, so
    // binding-level warnings on it are dev noise; the user-file overlay
    // path (`overlayUserSettings`) passes real warnings.
    return loaders.loadSettings(sections, allocator, null, null);
}

/// Load settings from data/default_settings.txt, falling back to the embedded
/// copy on parse failure (see DESIGN → Error Handling). The embedded copy is a
/// better fallback than hardcoded defaults - it preserves keybindings and
/// other authored values; hardcoded defaults are only the "embedded copy
/// missing entirely" panic case (a real bug). User preferences live in a
/// separate persistent `settings.txt` overlaid on top of these defaults -
/// see `overlayUserSettings`.
pub fn loadSettingsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    startup: *StartupMemory,
) Settings {
    return loadConfigWithFallback(Settings, file_source, allocator, "data/default_settings.txt", loadSettingsWrapped, parser.settings_key_map, startup);
}

/// Overlay a user's persistent `settings.txt` (in the persistent dir) on top
/// of the shipped defaults. The user file is the SAME FORMAT as
/// `data/default_settings.txt` but carries only the fields the player has
/// changed: scalars overlay per-field (user value wins, missing keeps
/// default); InputBindings overlay PER-ACTION - bindings for actions the
/// user file names are authoritative (replacing the defaults' bindings for
/// those actions), while actions it doesn't name fall back to their default
/// bindings (injected on load; persisted by the next debounced write -
/// see DESIGN → Input → Binding overlay semantics). A missing or
/// unparseable user file leaves the defaults untouched (with a warning).
/// `repair_write_needed` (out-param) is set when the user file PARSED and
/// LOADED but produced warnings (dropped bindings, unknown keys) - the merged
/// settings are authoritative there, so a full-format write repairs the
/// file and the warnings don't repeat next launch. NOT set when the user
/// file failed to parse or load: the overlay fell back to defaults, and
/// rewriting the file would overwrite possibly hand-recoverable content.
/// Replay-safe: settings are loaded once at startup, never during replay.
fn overlayUserSettings(
    defaults: Settings,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    startup: *StartupMemory,
    repair_write_needed: *bool,
) Settings {
    const warnings = &startup.warnings;
    const user_bytes = file_source.readFile(allocator, "settings.txt") catch {
        return defaults; // No user settings file → defaults are authoritative.
    };
    // `loadSettings` dupes each input_name into the allocator, so the merged
    // Settings OWNS its strings - it does not borrow from user_bytes. We free
    // user_bytes + the parsed sections eagerly on every path below (success
    // and error). See DESIGN → File System & IO → Settings ownership.

    const user_sections = parser.parseConfigFile(user_bytes, allocator) catch {
        allocator.free(user_bytes);
        warnings.append(allocator, std.fmt.allocPrint(allocator, "Failed to parse user settings.txt; using defaults.", .{}) catch
            @panic("failed to allocate startup warning")) catch
            @panic("failed to append startup warning");
        return defaults;
    };
    defer parser.freeParsedSections(user_sections, allocator);
    defer allocator.free(user_bytes);

    // Load with the defaults as the base - loadSettings overlays present
    // fields and overlays bindings per-action (user bindings for named
    // actions + injected defaults for unmentioned ones; the base's owned
    // binding strings are freed on replace). A file_format_version mismatch
    // or parse failure is recoverable (warn + keep defaults) per DESIGN →
    // Error Handling.
    const warnings_before = warnings.items.len;
    const merged = loaders.loadSettings(user_sections, allocator, defaults, warnings) catch {
        warnings.append(allocator, std.fmt.allocPrint(allocator, "Failed to load user settings.txt; using defaults.", .{}) catch
            @panic("failed to allocate startup warning")) catch
            @panic("failed to append startup warning");
        return defaults;
    };
    parser.validateKeys(user_sections, parser.settings_key_map, "settings.txt", allocator, warnings);
    if (warnings.items.len > warnings_before) {
        repair_write_needed.* = true;
        warnings.append(allocator, std.fmt.allocPrint(allocator, "settings.txt was out of date; a repaired copy is saved automatically (these settings warnings won't repeat).", .{}) catch
            @panic("failed to allocate startup warning")) catch
            @panic("failed to append startup warning");
    }
    return merged;
}

/// Load color theme definitions from data/color_themes.txt, falling back to
/// the embedded copy on parse failure (see DESIGN → Error Handling).
pub fn loadColorThemeDefinitionsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    startup: *StartupMemory,
) ColorThemeDefinitions {
    return loadConfigWithFallback(ColorThemeDefinitions, file_source, allocator, "data/color_themes.txt", loaders.loadColorThemeDefinitions, parser.color_theme_key_map, startup);
}

/// Load all weapon type definitions from data/weapon_types/, each falling
/// back to its embedded copy on parse failure (see DESIGN → Error Handling).
/// Each file is named after its WeaponType enum value (e.g. sword.txt).
pub fn loadWeaponTypeDefinitions(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    startup: *StartupMemory,
) [weapon_type_count]WeaponTypeDefinition {
    var definitions: [weapon_type_count]WeaponTypeDefinition = undefined;
    const fields = @typeInfo(WeaponType).@"enum".fields;

    inline for (fields, 0..) |field, index| {
        const file_path = "data/weapon_types/" ++ field.name ++ ".txt";
        definitions[index] = loadConfigWithFallback(
            WeaponTypeDefinition,
            file_source,
            allocator,
            file_path,
            loadWeaponTypeDefinitionWrapped,
            parser.weapon_type_key_map,
            startup,
        );
    }

    return definitions;
}

/// Load salvage definitions from data/salvage.txt, falling back to the
/// embedded copy on parse failure (see DESIGN → Error Handling).
pub fn loadSalvageDefinitionsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    startup: *StartupMemory,
) types.SalvageDefinitions {
    return loadConfigWithFallback(types.SalvageDefinitions, file_source, allocator, "data/salvage.txt", loaders.loadSalvageDefinitions, parser.salvage_key_map, startup);
}

/// Owns the session-long setup state (config definitions + FrameState) that
/// both platform drivers need. The `weapon_type_definitions` array is stored
/// BY VALUE here (not on the caller's stack) because GameStateHistory holds a
/// pointer to it - the pointer must remain valid for the whole session. On
/// native, the SessionSetup lives on run()'s stack for the game's duration;
/// on web, it's heap-allocated (the WebSession owns it) since main() returns
/// immediately. fixupPointers() must be called once the struct is in its final
/// memory location, so the history's pointer points to the right place.
pub const SessionSetup = struct {
    weapon_type_definitions: [weapon_type_count]WeaponTypeDefinition,
    /// The tracked startup memory (see StartupMemory): every retained
    /// config bytes + sections pair + the startup warning strings. Filled
    /// by `createSessionSetup`; freed by `freeSessionSetup` (the web
    /// re-boot's teardown - native never tears down, process lifetime).
    startup: StartupMemory,
    frame_state: FrameState,

    /// Point history.weapon_type_definitions at this struct's field. Must be
    /// called after the SessionSetup is in its final memory location (stack of
    /// the native driver, or heap-allocated for web).
    pub fn fixupPointers(self: *SessionSetup) void {
        self.frame_state.history.weapon_type_definitions = &self.weapon_type_definitions;
    }
};

/// Shared session setup: load all config, build the initial GameState, init the
/// history, and create the FrameState. Both native (run) and web (web.main)
/// call this instead of duplicating the load + init sequence. The caller is
/// responsible for placing the returned SessionSetup in a stable location and
/// calling fixupPointers() before driving frame().
pub fn createSessionSetup(
    allocator: std.mem.Allocator,
    file_source: *const FileSource,
    io: std.Io,
    backend: anytype,
) SessionSetup {
    var startup: StartupMemory = .{};

    const default_settings = loadSettingsFromDisk(file_source, allocator, &startup);
    var repair_write_needed = false;
    const settings = overlayUserSettings(default_settings, file_source, allocator, &startup, &repair_write_needed);
    backend.applyVsync(settings.vsync);
    const weapon_type_definitions = loadWeaponTypeDefinitions(file_source, allocator, &startup);
    const color_theme_definitions = loadColorThemeDefinitionsFromDisk(file_source, allocator, &startup);
    const salvage_definitions = loadSalvageDefinitionsFromDisk(file_source, allocator, &startup);

    const starting_game_state = GameState{
        .screen = .main_menu,
        .event_stack = &.{.{ .meta_event = .open_main_menu }},
        .player_data = .{},
        .camera = null,
        .editor = null,
        .replay_viewer = null,
        .campaign = null,
        .mission = null,
        .level = null,
        .hub = null,
    };

    // Create the history with a temporary pointer to weapon_type_definitions
    // (a local). The caller fixes this up via fixupPointers() once the
    // SessionSetup is in its final location. The temporary pointer is fine
    // because createSessionSetup hasn't returned yet - both the local and the
    // returned struct's field hold the same array value at this point.
    // Detect an existing autosave ONCE at startup so the main-menu Continue
    // button can show on a fresh launch (before PlayerData is populated). Not
    // per-frame - view() is pure and does no file access. See DESIGN → File
    // System & IO (autosave).
    const autosave_available = file_source.fileExists(writers.autosave_path);

    var history = GameStateHistory.init(
        allocator,
        starting_game_state,
        settings,
        &weapon_type_definitions,
        color_theme_definitions,
        salvage_definitions,
        file_source,
        io,
    );
    history.session.autosave_available = autosave_available;

    // Repair write: a user settings.txt that loaded but had stale entries
    // (dropped bindings, unknown keys) is rewritten full-format through the
    // same debounced path as preference changes (fires ~1s after boot; the
    // shutdown flushes cover a quick quit), so the startup warnings don't
    // repeat every launch. An unparseable user file does NOT trigger this -
    // see overlayUserSettings. See DESIGN → Input → Binding overlay semantics.
    if (repair_write_needed) state.markSettingsDirty(&history);

    // Surface startup warnings as a single pending error popup (see DESIGN →
    // Error Handling). The popup is modal: the player dismisses it (Escape /
    // Enter / the Dismiss button) before interacting with the main menu.
    if (startup.warnings.items.len > 0) {
        var message: std.ArrayList(u8) = .empty;
        defer message.deinit(allocator);
        for (startup.warnings.items, 0..) |warning, index| {
            if (index > 0) {
                message.appendSlice(allocator, "\n") catch
                    @panic("failed to assemble startup warning message");
            }
            message.appendSlice(allocator, warning) catch
                @panic("failed to assemble startup warning message");
        }
        history.session.setPendingError(history.history_arena.allocator(), message.items);
    }

    return .{
        .weapon_type_definitions = weapon_type_definitions,
        .startup = startup,
        .frame_state = .{
            .history = history,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .last_render_time = backend.realClockMicroseconds(),
        },
    };
}

/// Tear down a SessionSetup (the web re-boot's prerequisite - run at the
/// frame boundary, AFTER `frame` returned; a mid-frame swap would be a
/// use-after-free of the old history, which the running frame holds
/// references into). Frees the frame arena, everything the history owns
/// (its `deinit`: the session-owned config values, the session lists, the
/// arenas), and the tracked startup memory. ORDER: the history deinit
/// FIRST (the loaded config values are freed while the startup bytes are
/// still intact), then the section containers (`freeParsedSections`),
/// then the raw bytes, then the warning strings. The FileSource + IO are
/// NOT freed (owned by the platform driver, shared across re-boots).
/// Native never tears down (process lifetime); test histories living in
/// throwaway arenas skip it (the arena reclaims - deinit would also work,
/// arena frees are no-ops except the arena deinit).
pub fn freeSessionSetup(setup: *SessionSetup) void {
    const allocator = setup.frame_state.history.backing_allocator;
    setup.frame_state.frame_arena.deinit();
    setup.frame_state.history.deinit();
    for (setup.startup.allocations.items) |allocation| {
        parser.freeParsedSections(allocation.sections, allocator);
        if (allocation.config_bytes.len > 0) allocator.free(allocation.config_bytes);
    }
    setup.startup.allocations.deinit(allocator);
    for (setup.startup.warnings.items) |warning| allocator.free(warning);
    setup.startup.warnings.deinit(allocator);
}

// --- tests ---

const testing = std.testing;

test "loadConfigWithFallback: broken persistent shadow falls back to embedded + warns" {
    // The helper intentionally leaks config bytes + sections into the
    // allocator (process-lifetime in production). Wrap in an arena so the
    // test reclaims them.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded_io = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir with a broken data/default_settings.txt shadow.
    const scratch = "zig-cache/test-startup-fallback";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Write a broken settings shadow - invalid content that will fail to
    // parse. Goes directly through the persistent dir (FileSource.writeFile
    // rejects data/ paths by policy, so we write via the dir handle).
    dir.createDirPath(io, "data") catch @panic("failed to create data dir");
    dir.writeFile(io, .{ .sub_path = "data/default_settings.txt", .data = "this is not valid config" }) catch
        @panic("failed to write broken shadow");

    var startup: StartupMemory = .{};
    const settings = loadSettingsFromDisk(&file_source, allocator, &startup);

    // The embedded copy loaded (keybindings present, not the empty-default).
    try testing.expect(settings.input_bindings.len > 0);
    // One warning was recorded.
    try testing.expectEqual(@as(usize, 1), startup.warnings.items.len);
    // The warning mentions the path.
    try testing.expect(std.mem.indexOf(u8, startup.warnings.items[0], "data/default_settings.txt") != null);
    // Both retained attempts are tracked for the teardown: the shadow's
    // (it parses but fails to LOAD, so its bytes + sections stay retained -
    // see loadConfigWithFallback) + the embedded retry's.
    try testing.expectEqual(@as(usize, 2), startup.allocations.items.len);
}

test "loadConfigWithFallback: no shadow uses embedded directly, no warning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded_io = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir with NO data/default_settings.txt shadow.
    const scratch = "zig-cache/test-startup-no-shadow";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    var startup: StartupMemory = .{};
    const settings = loadSettingsFromDisk(&file_source, allocator, &startup);

    // The embedded copy loaded.
    try testing.expect(settings.input_bindings.len > 0);
    // No warning - the normal read path (persistent miss → embedded hit) is
    // not a "fallback"; only a parse failure that retries embedded is.
    try testing.expectEqual(@as(usize, 0), startup.warnings.items.len);
    // The normal embedded hit is still a RETAINED attempt (tracked).
    try testing.expectEqual(@as(usize, 1), startup.allocations.items.len);
}

/// Build self-owned defaults WITHOUT going through loadConfigWithFallback
/// (which intentionally leaks the raw bytes for process lifetime - a leak
/// `testing.allocator` would flag). readEmbeddedFile + parse + loadSettings
/// (dupes) + free bytes + free sections gives owned defaults with no leak.
/// The defaults base for the overlay tests below.
fn loadOwnedDefaults(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
) Settings {
    const defaults_bytes = file_source.readEmbeddedFile(allocator, "data/default_settings.txt") catch
        @panic("embedded default settings missing");
    const defaults_sections = parser.parseConfigFile(defaults_bytes, allocator) catch
        @panic("failed to parse embedded default settings");
    const defaults = loaders.loadSettings(defaults_sections, allocator, null, null) catch
        @panic("failed to load embedded default settings");
    parser.freeParsedSections(defaults_sections, allocator);
    allocator.free(defaults_bytes);
    return defaults;
}

// Leak-checked regression test for overlayUserSettings under `testing.allocator`
// (no arena). Arena-wrapping masks two classes of bug: leaks (arena free is a
// no-op, so a forgotten free is invisible) and use-after-free (freed memory
// stays mapped and readable, so a dangling slice returns stale-but-valid
// bytes). loadSettings now dupes each input_name so the merged Settings OWNS
// its strings and overlayUserSettings frees user_bytes + the parsed sections
// eagerly - so the overlay path is leak-clean and can be tested under
// testing.allocator, whose leak detection catches a forgotten free (the
// remaining risk after the ownership fix). The use-after-free class is gone
// by construction (nothing borrows from user_bytes anymore). See DESIGN →
// File System & IO → Settings ownership + Testing discipline.
test "overlayUserSettings: leak-clean under testing.allocator (owned strings)" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir so no settings.txt lands in the project root.
    const scratch = "zig-cache/test-startup-overlay";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    const defaults = loadOwnedDefaults(&file_source, allocator);
    try testing.expect(defaults.input_bindings.len > 0);

    // Write a user settings.txt with a couple of distinct, checkable bindings.
    const user_settings =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name KeyZ
        \\action undo
        \\context anytime
        \\
        \\input_type key
        \\input_name KeyY
        \\action redo
        \\context anytime
    ;
    dir.writeFile(io, .{ .sub_path = "settings.txt", .data = user_settings }) catch
        @panic("failed to write user settings.txt");

    var startup: StartupMemory = .{};
    var repair_write_needed = false;
    const merged = overlayUserSettings(defaults, &file_source, allocator, &startup, &repair_write_needed);
    // No warnings on a valid user file - so no warning strings were allocated
    // into `allocator` (which would leak since the test doesn't free them) -
    // and no repair write is scheduled (nothing to repair). The overlay path
    // frees its bytes + sections eagerly, so nothing is tracked either.
    try testing.expectEqual(@as(usize, 0), startup.warnings.items.len);
    try testing.expectEqual(@as(usize, 0), startup.allocations.items.len);
    try testing.expect(!repair_write_needed);

    // Overlay is PER-ACTION: the user's bindings for undo/redo win (owned
    // strings, duped by loadSettings; the defaults' undo/redo bindings are
    // NOT carried over), while every action the user file doesn't mention
    // falls back to its default binding - injected, so no official binding
    // is lost to the full-set replace (the skip_level gap). The old base
    // bindings were freed inside loadSettings on replace - no leak.
    var found_user_undo = false;
    var found_user_redo = false;
    for (merged.input_bindings) |binding| {
        switch (binding.action) {
            .undo => {
                // User's binding replaced the default (ctrl+KeyZ) exactly.
                try testing.expectEqualStrings("KeyZ", binding.input.key);
                try testing.expect(!binding.modifiers.ctrl);
                found_user_undo = true;
            },
            .redo => {
                try testing.expectEqualStrings("KeyY", binding.input.key);
                found_user_redo = true;
            },
            else => {},
        }
    }
    try testing.expect(found_user_undo);
    try testing.expect(found_user_redo);
    // The unmentioned defaults came along: the merged set is strictly larger
    // than the user's two bindings.
    try testing.expect(merged.input_bindings.len > 2);

    // Round-trip through writeSettings (buffer lives in allocator; free it).
    const written = try writers.writeSettings(merged, allocator);
    defer allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "input_name KeyZ") != null);
    try testing.expect(std.mem.indexOf(u8, written, "input_name KeyY") != null);
    // The write is full-format including the binding context (the field the
    // next load REQUIRES - a written file must reparse cleanly).
    try testing.expect(std.mem.indexOf(u8, written, "action undo\ncontext anytime") != null);

    // Free the merged bindings (owned strings + slice). testing.allocator's
    // leak detection at test-end catches if overlayUserSettings or
    // loadSettings forgot to free user_bytes / the old base strings / the
    // parsed sections - the arena-wrapped tests can't see those.
    loaders.freeSettings(merged, allocator);
}

// Stale user settings (pre-rename binding + unknown key): the overlay sets
// the repair flag, and the heal write (exactly what writeSettingsToFile
// persists) produces a file that re-overlays with ZERO warnings - the
// idempotency contract that makes the startup popup not repeat next launch.
// Under testing.allocator (no arena): the warning strings are allocPrint'd
// single allocations, freed by the test, so the leak checker still covers the
// overlay path itself (same discipline as the leak test above).
test "overlayUserSettings: stale entries set repair flag; heal write is idempotent" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    // Scratch persistent dir so no settings.txt lands in the project root.
    const scratch = "zig-cache/test-startup-repair";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Stale user file: `toggle_options_menu` is the pre-rename name of
    // `escape` (warned + dropped at load), `camra_zoom` is an unknown key
    // (warned), plus one valid binding so the file isn't only garbage.
    const user_settings =
        \\Metadata
        \\file_format_version 2
        \\
        \\Display
        \\camra_zoom 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name KeyZ
        \\action undo
        \\context anytime
        \\
        \\input_type key
        \\input_name KeyO
        \\action toggle_options_menu
        \\context anytime
    ;
    dir.writeFile(io, .{ .sub_path = "settings.txt", .data = user_settings }) catch
        @panic("failed to write user settings.txt");

    const defaults = loadOwnedDefaults(&file_source, allocator);
    var startup: StartupMemory = .{};
    defer startup.warnings.deinit(allocator);
    defer for (startup.warnings.items) |warning| allocator.free(warning);
    var repair_write_needed = false;
    const merged = overlayUserSettings(defaults, &file_source, allocator, &startup, &repair_write_needed);

    // The stale binding was warned by name, the repair flag is set, and the
    // reassurance line was appended (the popup tells the player it's fixed).
    var found_stale_warning = false;
    var found_repair_note = false;
    for (startup.warnings.items) |warning| {
        if (std.mem.indexOf(u8, warning, "toggle_options_menu") != null) found_stale_warning = true;
        if (std.mem.indexOf(u8, warning, "repaired copy") != null) found_repair_note = true;
    }
    try testing.expect(found_stale_warning);
    try testing.expect(repair_write_needed);
    try testing.expect(found_repair_note);
    // The dropped binding's action (renamed to `escape`) got its default
    // injected - the stale entry costs the player nothing.
    var found_escape = false;
    for (merged.input_bindings) |binding| {
        if (binding.action == .escape) found_escape = true;
    }
    try testing.expect(found_escape);

    // Heal write: exactly what writeSettingsToFile persists. Write to disk,
    // re-overlay with fresh defaults: zero warnings, no repair flag.
    const written = try writers.writeSettings(merged, allocator);
    defer allocator.free(written);
    dir.writeFile(io, .{ .sub_path = "settings.txt", .data = written }) catch
        @panic("failed to write repaired settings.txt");
    loaders.freeSettings(merged, allocator);

    const fresh_defaults = loadOwnedDefaults(&file_source, allocator);
    var startup_after: StartupMemory = .{};
    var repair_write_needed_after = false;
    const remerged = overlayUserSettings(fresh_defaults, &file_source, allocator, &startup_after, &repair_write_needed_after);
    try testing.expectEqual(@as(usize, 0), startup_after.warnings.items.len);
    try testing.expect(!repair_write_needed_after);
    loaders.freeSettings(remerged, allocator);
}

// The data-loss guard: a user file that fails to load must NOT set the
// repair flag - the overlay fell back to defaults, and rewriting the file
// would overwrite possibly hand-recoverable content. (The garbage content
// actually parses - lowercase lines become header-less key-value pairs -
// and then fails to load: no Metadata/file_format_version. Both the
// parse-fail and load-fail branches share this guard.) The warning still
// repeats (deliberately) until the player fixes or deletes the file.
test "overlayUserSettings: invalid user file sets no repair flag" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-startup-repair-no-write";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    dir.writeFile(io, .{ .sub_path = "settings.txt", .data = "this is not valid config" }) catch
        @panic("failed to write broken settings.txt");

    const defaults = loadOwnedDefaults(&file_source, allocator);
    var startup: StartupMemory = .{};
    defer startup.warnings.deinit(allocator);
    defer for (startup.warnings.items) |warning| allocator.free(warning);
    var repair_write_needed = false;
    const merged = overlayUserSettings(defaults, &file_source, allocator, &startup, &repair_write_needed);

    // Warned (load failure → defaults), and NO repair write scheduled.
    try testing.expectEqual(@as(usize, 1), startup.warnings.items.len);
    try testing.expect(!repair_write_needed);
    // The broken file was left untouched on disk (the observable half of the
    // guard: no write fired over it).
    const disk_bytes = file_source.readFile(allocator, "settings.txt") catch
        @panic("failed to read back settings.txt");
    defer allocator.free(disk_bytes);
    try testing.expectEqualStrings("this is not valid config", disk_bytes);
    loaders.freeSettings(merged, allocator);
}

// The wiring contract: createSessionSetup schedules the repair write when
// the startup overlay repaired stale entries, and firing it (frame()'s
// path, clock advanced past the 1s debounce) rewrites settings.txt into a
// file that re-overlays warning-free. Arena-wrapped: createSessionSetup
// intentionally leaks config bytes + warnings for the session (production
// lifetime), and the write itself goes through the real FileSource into the
// scratch persistent dir.
test "createSessionSetup: stale settings.txt schedules the repair write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded_io = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-startup-repair-wiring";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);

    // Same stale shape as the overlay test: a pre-rename binding.
    const user_settings =
        \\Metadata
        \\file_format_version 2
        \\
        \\InputBindings
        \\input_type key
        \\input_name KeyO
        \\action toggle_options_menu
        \\context anytime
    ;
    dir.writeFile(io, .{ .sub_path = "settings.txt", .data = user_settings }) catch
        @panic("failed to write user settings.txt");

    // Minimal fake backend: createSessionSetup only applies vsync + reads
    // the clock.
    const FakeBackend = struct {
        fn applyVsync(_: *const @This(), _: bool) void {}
        fn realClockMicroseconds(_: *const @This()) u64 {
            return 0;
        }
    };
    var fake_backend = FakeBackend{};
    var setup = createSessionSetup(allocator, &file_source, io, &fake_backend);

    // The repair write was scheduled on the debounced-write machinery.
    var settings_write_scheduled = false;
    for (setup.frame_state.history.session.pending_writes) |slot| {
        if (slot) |entry| {
            if (entry.tag == .settings) settings_write_scheduled = true;
        }
    }
    try testing.expect(settings_write_scheduled);

    // Fire it (frame()'s path; the clock is past the 1s debounce deadline
    // markWriteDirty set from session_clock = 0), then re-overlay: the
    // on-disk file is warning-free - the popup won't repeat next launch.
    setup.frame_state.history.session.fireElapsedWrites(&setup.frame_state.history, 2 * std.time.us_per_s);

    var startup_after: StartupMemory = .{};
    var repair_write_needed_after = false;
    const remerged = overlayUserSettings(
        loadOwnedDefaults(&file_source, allocator),
        &file_source,
        allocator,
        &startup_after,
        &repair_write_needed_after,
    );
    try testing.expectEqual(@as(usize, 0), startup_after.warnings.items.len);
    try testing.expect(!repair_write_needed_after);
    // The stale name is gone from disk: the written file's undo binding
    // round-trips (any default binding present proves the full-format write;
    // the stale line would fail the overlay above if it survived).
    var found_undo = false;
    for (remerged.input_bindings) |binding| {
        if (binding.action == .undo) found_undo = true;
    }
    try testing.expect(found_undo);
}

// The web re-boot's teardown contract: the createSessionSetup +
// freeSessionSetup round-trip is leak-clean under testing.allocator (NO
// arena - the leak checker catches every startup allocation the tracking
// misses and every history-owned allocation the deinit misses; the web
// driver re-boots the session after every Import Game, so a miss is a
// per-boot leak). The drain runs the real event path (open_main_menu -> the
// main menu, queued sounds + a snapshot + an idle point) so the teardown
// covers non-empty history machinery, not just the fresh state. The user
// settings.txt carries a stale entry so the overlay's repair + warning
// paths (tracked + freed) run too.
test "createSessionSetup + freeSessionSetup round-trip: leak-clean under testing.allocator" {
    const allocator = testing.allocator;
    var threaded_io = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const scratch = "zig-cache/test-startup-teardown";
    const dir = std.Io.Dir.cwd().createDirPathOpen(io, scratch, .{
        .open_options = .{ .access_sub_paths = true, .iterate = true },
    }) catch @panic("failed to create scratch dir");
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch {};
    const file_source = FileSource.init(io, dir);
    dir.writeFile(io, .{ .sub_path = "settings.txt", .data =
        \\Metadata
        \\file_format_version 2
        \\
        \\Display
        \\camra_zoom 2
    }) catch @panic("failed to write user settings.txt");

    // Minimal fake backend (the repair-write test's): createSessionSetup
    // only applies vsync + reads the clock.
    const FakeBackend = struct {
        fn applyVsync(_: *const @This(), _: bool) void {}
        fn realClockMicroseconds(_: *const @This()) u64 {
            return 0;
        }
    };
    var fake_backend = FakeBackend{};
    var setup = createSessionSetup(allocator, &file_source, io, &fake_backend);

    // The startup repair + warning paths ran (tracked + freed by the
    // teardown below - asserted by the leak checker itself).
    try testing.expect(setup.startup.warnings.items.len > 0);
    try testing.expect(setup.startup.allocations.items.len > 0);

    // Drive the queued open_main_menu through the real drain (the harness's
    // runToIdle shape; event_handlers is imported inside the test block so
    // this file stays a leaf for non-test builds).
    const event_handlers = @import("event_handlers.zig");
    while (setup.frame_state.history.current_state.event_stack.len > 0) {
        event_handlers.processEvent(&setup.frame_state.history);
        if (setup.frame_state.history.load_error) @panic("teardown test content should be valid");
        setup.frame_state.history.current_state.waiting = null;
    }
    setup.frame_state.history.maybeRecordIdlePoint(true);
    try testing.expect(state.Screen.main_menu == setup.frame_state.history.current_state.screen);

    // The teardown: everything above is freed or the leak checker fires.
    freeSessionSetup(&setup);
}
