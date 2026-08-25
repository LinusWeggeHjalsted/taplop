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
const parser = @import("parser.zig");
const loaders = @import("loaders.zig");
const writers = @import("writers.zig");
const file_source_mod = @import("file_source.zig");

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
};

/// Collected startup warnings (one per config file that fell back to its
/// embedded copy). Passed by-mutable-pointer to each loader; the helper
/// appends to it. `createSessionSetup` concatenates the entries into a single
/// `pending_error` after the history is created (the popup lives on
/// SessionState, which is on GameStateHistory). The warning strings are
/// allocated in the session allocator (process-lifetime); `setPendingError`
/// dupes the combined message into `history_arena`, so these are leaked in
/// the GPA — accepted (small, rare; same lifetime contract as the config
/// bytes themselves). See DESIGN → Error Handling → three contexts.
const Warnings = *std.ArrayList([]const u8);

/// Read + parse a config file and load it via `load_fn`, falling back to the
/// embedded copy if the first attempt (persistent-dir shadow → embedded) fails
/// at any stage — read, parse, or `load_fn`. On a successful first attempt,
/// returns the loaded value with no warning. On a failed first attempt +
/// successful embedded retry, appends a warning to `warnings` and returns the
/// value. If the embedded copy also fails, panics — shipped content is broken,
/// a real bug. See DESIGN → Error Handling → three contexts.
///
/// `load_fn` has shape `fn ([]const parser.Section, std.mem.Allocator) anyerror!T`
/// (the common loader shape; `loadWeaponTypeDefinition` is wrapped to match).
/// The bytes from the successful attempt are leaked into `allocator`
/// (process-lifetime on both platforms) and referenced by the returned value's
/// slices — same lifetime contract as the existing `parseConfigFileFromPath`
/// path.
fn loadConfigWithFallback(
    comptime T: type,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    path: []const u8,
    load_fn: *const fn ([]const parser.Section, std.mem.Allocator) anyerror!T,
    key_map: std.StaticStringMap([]const []const u8),
    warnings: Warnings,
) T {
    // First attempt: normal read order (persistent dir → embedded).
    if (file_source.readFile(allocator, path)) |bytes| {
        if (parser.parseConfigFile(bytes, allocator)) |sections| {
            if (load_fn(sections, allocator)) |result| {
                parser.validateKeys(sections, key_map, path, allocator, warnings);
                return result;
            } else |_| {}
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
    // Validate the embedded copy too — an unknown key in a parsing-OK
    // embedded file is a softer issue worth surfacing (the panic above
    // fires first on a parse/load failure).
    parser.validateKeys(sections, key_map, path, allocator, warnings);

    warnings.append(allocator, std.fmt.allocPrint(allocator,
        "Failed to parse {s}; using built-in default.", .{path}) catch
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
    return loaders.loadSettings(sections, allocator, null);
}

/// Load settings from data/default_settings.txt, falling back to the embedded
/// copy on parse failure (see DESIGN → Error Handling). The embedded copy is a
/// better fallback than hardcoded defaults — it preserves keybindings and
/// other authored values; hardcoded defaults are only the "embedded copy
/// missing entirely" panic case (a real bug). User preferences live in a
/// separate persistent `settings.txt` overlaid on top of these defaults —
/// see `overlayUserSettings`.
pub fn loadSettingsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: Warnings,
) Settings {
    return loadConfigWithFallback(Settings, file_source, allocator, "data/default_settings.txt", loadSettingsWrapped, parser.settings_key_map, warnings);
}

/// Overlay a user's persistent `settings.txt` (in the persistent dir) on top
/// of the shipped defaults. The user file is the SAME FORMAT as
/// `data/default_settings.txt` but carries only the fields the player has
/// changed: scalars overlay per-field (user value wins, missing keeps default);
/// InputBindings, if present, REPLACE the default binding set entirely (the
/// user's bindings are authoritative — see DESIGN → Input). A missing or
/// unparseable user file leaves the defaults untouched (with a warning).
/// Replay-safe: settings are loaded once at startup, never during replay.
pub fn overlayUserSettings(
    defaults: Settings,
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: Warnings,
) Settings {
    const user_bytes = file_source.readFile(allocator, "settings.txt") catch {
        return defaults; // No user settings file → defaults are authoritative.
    };
    // `loadSettings` dupes each input_name into the allocator, so the merged
    // Settings OWNS its strings — it does not borrow from user_bytes. We free
    // user_bytes + the parsed sections eagerly on every path below (success
    // and error). See DESIGN → File System & IO → Settings ownership.

    const user_sections = parser.parseConfigFile(user_bytes, allocator) catch {
        allocator.free(user_bytes);
        warnings.append(allocator, std.fmt.allocPrint(allocator,
            "Failed to parse user settings.txt; using defaults.", .{}) catch
            @panic("failed to allocate startup warning")) catch
            @panic("failed to append startup warning");
        return defaults;
    };
    defer parser.freeParsedSections(user_sections, allocator);
    defer allocator.free(user_bytes);

    // Load with the defaults as the base — loadSettings overlays present
    // fields and replaces bindings if the user file has an InputBindings
    // section (freeing the base's owned binding strings on replace). A
    // file_format_version mismatch or parse failure is recoverable (warn +
    // keep defaults) per DESIGN → Error Handling.
    const merged = loaders.loadSettings(user_sections, allocator, defaults) catch {
        warnings.append(allocator, std.fmt.allocPrint(allocator,
            "Failed to load user settings.txt; using defaults.", .{}) catch
            @panic("failed to allocate startup warning")) catch
            @panic("failed to append startup warning");
        return defaults;
    };
    parser.validateKeys(user_sections, parser.settings_key_map, "settings.txt", allocator, warnings);
    return merged;
}

/// Load color theme definitions from data/color_themes.txt, falling back to
/// the embedded copy on parse failure (see DESIGN → Error Handling).
pub fn loadColorThemeDefinitionsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: Warnings,
) ColorThemeDefinitions {
    return loadConfigWithFallback(ColorThemeDefinitions, file_source, allocator, "data/color_themes.txt", loaders.loadColorThemeDefinitions, parser.color_theme_key_map, warnings);
}

/// Load all weapon type definitions from data/weapon_types/, each falling
/// back to its embedded copy on parse failure (see DESIGN → Error Handling).
/// Each file is named after its WeaponType enum value (e.g. sword.txt).
pub fn loadWeaponTypeDefinitions(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: Warnings,
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
            warnings,
        );
    }

    return definitions;
}

/// Load salvage definitions from data/salvage.txt, falling back to the
/// embedded copy on parse failure (see DESIGN → Error Handling).
pub fn loadSalvageDefinitionsFromDisk(
    file_source: *const FileSource,
    allocator: std.mem.Allocator,
    warnings: Warnings,
) types.SalvageDefinitions {
    return loadConfigWithFallback(types.SalvageDefinitions, file_source, allocator, "data/salvage.txt", loaders.loadSalvageDefinitions, parser.salvage_key_map, warnings);
}

/// Owns the session-long setup state (config definitions + FrameState) that
/// both platform drivers need. The `weapon_type_definitions` array is stored
/// BY VALUE here (not on the caller's stack) because GameStateHistory holds a
/// pointer to it — the pointer must remain valid for the whole session. On
/// native, the SessionSetup lives on run()'s stack for the game's duration;
/// on web, it's heap-allocated (the WebSession owns it) since main() returns
/// immediately. fixupPointers() must be called once the struct is in its final
/// memory location, so the history's pointer points to the right place.
pub const SessionSetup = struct {
    weapon_type_definitions: [weapon_type_count]WeaponTypeDefinition,
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
    var warnings: std.ArrayList([]const u8) = .empty;

    const default_settings = loadSettingsFromDisk(file_source, allocator, &warnings);
    const settings = overlayUserSettings(default_settings, file_source, allocator, &warnings);
    backend.applyVsync(settings.vsync);
    const weapon_type_definitions = loadWeaponTypeDefinitions(file_source, allocator, &warnings);
    const color_theme_definitions = loadColorThemeDefinitionsFromDisk(file_source, allocator, &warnings);
    const salvage_definitions = loadSalvageDefinitionsFromDisk(file_source, allocator, &warnings);

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
    // because createSessionSetup hasn't returned yet — both the local and the
    // returned struct's field hold the same array value at this point.
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

    // Surface startup warnings as a single pending error popup (see DESIGN →
    // Error Handling). The popup is modal: the player dismisses it (Escape /
    // Enter / the Dismiss button) before interacting with the main menu.
    if (warnings.items.len > 0) {
        var message: std.ArrayList(u8) = .empty;
        for (warnings.items, 0..) |warning, index| {
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
        .frame_state = .{
            .history = history,
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .last_render_time = backend.realClockMicroseconds(),
        },
    };
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

    // Write a broken settings shadow — invalid content that will fail to
    // parse. Goes directly through the persistent dir (FileSource.writeFile
    // rejects data/ paths by policy, so we write via the dir handle).
    dir.createDirPath(io, "data") catch @panic("failed to create data dir");
    dir.writeFile(io, .{ .sub_path = "data/default_settings.txt", .data = "this is not valid config" }) catch
        @panic("failed to write broken shadow");

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = loadSettingsFromDisk(&file_source, allocator, &warnings);

    // The embedded copy loaded (keybindings present, not the empty-default).
    try testing.expect(settings.input_bindings.len > 0);
    // One warning was recorded.
    try testing.expectEqual(@as(usize, 1), warnings.items.len);
    // The warning mentions the path.
    try testing.expect(std.mem.indexOf(u8, warnings.items[0], "data/default_settings.txt") != null);
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

    var warnings: std.ArrayList([]const u8) = .empty;
    const settings = loadSettingsFromDisk(&file_source, allocator, &warnings);

    // The embedded copy loaded.
    try testing.expect(settings.input_bindings.len > 0);
    // No warning — the normal read path (persistent miss → embedded hit) is
    // not a "fallback"; only a parse failure that retries embedded is.
    try testing.expectEqual(@as(usize, 0), warnings.items.len);
}

// Leak-checked regression test for overlayUserSettings under `testing.allocator`
// (no arena). Arena-wrapping masks two classes of bug: leaks (arena free is a
// no-op, so a forgotten free is invisible) and use-after-free (freed memory
// stays mapped and readable, so a dangling slice returns stale-but-valid
// bytes). loadSettings now dupes each input_name so the merged Settings OWNS
// its strings and overlayUserSettings frees user_bytes + the parsed sections
// eagerly — so the overlay path is leak-clean and can be tested under
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

    // Build self-owned defaults WITHOUT going through loadConfigWithFallback
    // (which intentionally leaks the raw bytes for process lifetime — a leak
    // testing.allocator would flag). readEmbeddedFile + parse + loadSettings
    // (dupes) + free bytes + free sections gives owned defaults with no leak.
    const defaults_bytes = file_source.readEmbeddedFile(allocator, "data/default_settings.txt") catch
        @panic("embedded default settings missing");
    const defaults_sections = parser.parseConfigFile(defaults_bytes, allocator) catch
        @panic("failed to parse embedded default settings");
    const defaults = loaders.loadSettings(defaults_sections, allocator, null) catch
        @panic("failed to load embedded default settings");
    parser.freeParsedSections(defaults_sections, allocator);
    allocator.free(defaults_bytes);
    try testing.expect(defaults.input_bindings.len > 0);

    // Write a user settings.txt with a couple of distinct, checkable bindings.
    const user_settings =
        \\Metadata
        \\file_format_version 1
        \\
        \\InputBindings
        \\input_type key
        \\input_name KeyZ
        \\action undo
        \\
        \\input_type key
        \\input_name KeyY
        \\action redo
    ;
    dir.writeFile(io, .{ .sub_path = "settings.txt", .data = user_settings }) catch
        @panic("failed to write user settings.txt");

    var warnings: std.ArrayList([]const u8) = .empty;
    const merged = overlayUserSettings(defaults, &file_source, allocator, &warnings);
    // No warnings on a valid user file — so no warning strings were allocated
    // into `allocator` (which would leak since the test doesn't free them).
    try testing.expectEqual(@as(usize, 0), warnings.items.len);

    // Overlay replaced the binding set with the two user bindings (owned
    // strings, duped by loadSettings). The old base bindings were freed
    // inside loadSettings on replace — no leak.
    try testing.expectEqual(@as(usize, 2), merged.input_bindings.len);
    try testing.expectEqualStrings("KeyZ", merged.input_bindings[0].input.key);
    try testing.expectEqualStrings("KeyY", merged.input_bindings[1].input.key);

    // Round-trip through writeSettings (buffer lives in allocator; free it).
    const written = try writers.writeSettings(merged, allocator);
    defer allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "input_name KeyZ") != null);
    try testing.expect(std.mem.indexOf(u8, written, "input_name KeyY") != null);

    // Free the merged bindings (owned strings + slice). testing.allocator's
    // leak detection at test-end catches if overlayUserSettings or
    // loadSettings forgot to free user_bytes / the old base strings / the
    // parsed sections — the arena-wrapped tests can't see those.
    loaders.freeSettings(merged, allocator);
}
