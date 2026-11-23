//! Sound asset overview generator - a build tool, never part of the game.
//! `zig build sound-report` (wrapped by scripts/sound_report.sh) walks the
//! engine's own enums (SoundId / SkillId / Action / ItemActionSound) and
//! writes `sound_report.md` at the project root: EVERY wired sound path, its
//! status against the shipped assets + the persistent-dir shadows, and what
//! triggers it. Enum-keyed so new skills/actions/bases appear automatically -
//! no hand-maintained list to drift. See DESIGN → Audio (layered cues).

const std = @import("std");
const types = @import("types.zig");
const file_source = @import("file_source.zig");
const lookups = @import("generated_lookups.zig");
const persistent_path = @import("persistent_path.zig");

/// One reported sound asset: the project-relative path (extension-less -
/// `.wav`/`.ogg` both resolve, `.wav` tried first) + the human description.
const SoundAsset = struct {
    path: []const u8,
    description: []const u8,
};

/// Tally of the reported statuses (the tool's stdout summary line).
const ReportCounts = struct {
    shipped: usize = 0,
    shadowed: usize = 0,
    missing: usize = 0,
};

/// Where an asset's files were found: which extension resolved in the
/// shipped `assets/` tree and which in the persistent dir (`.wav`/`.ogg`;
/// null = no file there). A persistent-dir copy wins over a shipped one at
/// runtime - see DESIGN → File System & IO → Modding by shadowing.
const AssetStatus = struct {
    shipped_ext: ?[]const u8 = null,
    shadowed_ext: ?[]const u8 = null,
};

/// The audio extensions in runtime lookup order - shared with the
/// FileSource (the single source of the `.wav`-first policy).
const audio_extensions = file_source.FileSource.audio_file_extensions;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();

    const persistent_dir_path = try resolvePersistentPath(allocator);
    const persistent_dir: ?std.Io.Dir = cwd.openDir(io, persistent_dir_path, .{
        .access_sub_paths = true,
    }) catch null;
    defer if (persistent_dir) |dir| std.Io.Dir.close(dir, io);

    var report: std.ArrayList(u8) = .empty;
    var counts: ReportCounts = .{};

    try report.print(allocator,
        \\# taplop sound asset overview
        \\
        \\Auto-generated from the engine's enums - every wired sound is listed,
        \\and new skills/actions appear here automatically. Regenerate with
        \\`scripts/sound_report.sh`.
        \\
        \\**How to add or replace a sound:** place a file at
        \\`{s}/<path>` - the persistent directory overrides the shipped copy
        \\(asset shadowing). Both `.wav` and `.ogg` are accepted (`.wav` is
        \\looked up first). A layer file dropped mid-session plays on the next
        \\cast/click without relaunching; bases and music load at launch.
        \\
        \\**Silence = not authored yet.** There are NO fallbacks: a missing
        \\base or layer plays nothing, so this file's status column is the
        \\complete truth about what is done and what is missing.
        \\
        \\Every layered trigger plays TWO files at once: a category `_base`
        \\plus a specific `_layer`. Which half is percussive vs ambient is a
        \\per-family authoring choice - the names don't presume it.
        \\
        \\## Music (looping streams)
        \\
        \\One layer fades in per aggro'd enemy (~1s crossfade), in order -
        \\write as many as you like, up to {d}. ALL stems (base included)
        \\must be identical-length, sample-aligned loops (one DAW session).
        \\
    , .{ persistent_dir_path, types.max_music_layers });
    try reportAsset(allocator, &report, cwd, persistent_dir, io, .{
        .path = "assets/audio/music/ambient",
        .description = "the always-on base track, plays everywhere",
    }, &counts);
    var layer_index: usize = 1;
    while (layer_index <= types.max_music_layers) : (layer_index += 1) {
        const path = try std.fmt.allocPrint(
            allocator,
            "assets/audio/music/ambient_layer_{d}",
            .{layer_index},
        );
        const description = try std.fmt.allocPrint(
            allocator,
            "intensity layer {d} - on while {d}+ enemies are aggro'd",
            .{ layer_index, layer_index },
        );
        try reportAsset(allocator, &report, cwd, persistent_dir, io, .{
            .path = path,
            .description = description,
        }, &counts);
    }

    try report.print(allocator,
        \\
        \\## Bases (the category layer of a layered cue)
        \\
    , .{});
    for (std.meta.tags(types.SoundId)) |sound| {
        if (!isBase(sound)) continue;
        try reportAsset(allocator, &report, cwd, persistent_dir, io, .{
            .path = try std.fmt.allocPrint(allocator, "assets/audio/sfx/{s}", .{@tagName(sound)}),
            .description = baseDescription(sound),
        }, &counts);
    }

    try report.print(allocator,
        \\
        \\## One-shot event sounds (played alone, no layer)
        \\
    , .{});
    for (std.meta.tags(types.SoundId)) |sound| {
        if (isBase(sound)) continue;
        try reportAsset(allocator, &report, cwd, persistent_dir, io, .{
            .path = try std.fmt.allocPrint(allocator, "assets/audio/sfx/{s}", .{@tagName(sound)}),
            .description = oneShotDescription(sound),
        }, &counts);
    }

    try report.print(allocator,
        \\
        \\## Skill layers (played over the skill-type base on every cast)
        \\
    , .{});
    for (std.meta.tags(types.SkillId)) |skill_id| {
        const base_name = if (lookups.getSkillDefinition(skill_id)) |definition|
            @tagName(types.skillTypeBaseSound(definition.skill_type))
        else
            "<unknown base>";
        const description = try std.fmt.allocPrint(allocator, "the {s} skill - plays over {s}", .{ @tagName(skill_id), base_name });
        try reportAsset(allocator, &report, cwd, persistent_dir, io, .{
            .path = try std.fmt.allocPrint(allocator, "assets/audio/sfx/skills/{s}_layer", .{@tagName(skill_id)}),
            .description = description,
        }, &counts);
    }

    try report.print(allocator,
        \\
        \\## Button layers (played over button_base_up when the action fires)
        \\
        \\Keyboard-triggered actions play the layer alone (no click sounds).
        \\Skill-slot actions fire their layer on prepare/unprepare only - the
        \\auto-fire cast plays the full skill cue instead.
        \\
        \\NOT listed (deliberately unwired - a dropped layer file would not
        \\play): the zoom keys + cursor keys (the wheel/mouse paths carry no
        \\sound; keys shouldn't be noisier), error-scroll ticks,
        \\`dump_event_log` + `skip_level` (dev tools), `confirm` (the
        \\simulated tile click plays the move/skill sounds instead).
        \\
    , .{});
    for (std.meta.tags(types.Action)) |action| {
        if (types.actionSoundUnwired(action)) continue;
        const note: []const u8 = if (types.actionIsSkillSlot(action))
            "skill slot - prepare/unprepare feedback (the cast itself plays the skill cue)"
        else
            "fires on the button release + the keybind, when the action does something";
        const description = try std.fmt.allocPrint(allocator, "`{s}` - {s}", .{ @tagName(action), note });
        try reportAsset(allocator, &report, cwd, persistent_dir, io, .{
            .path = try std.fmt.allocPrint(allocator, "assets/audio/sfx/buttons/{s}_layer", .{@tagName(action)}),
            .description = description,
        }, &counts);
    }

    try report.print(allocator,
        \\
        \\## Item layers (played over item_base)
        \\
    , .{});
    for (std.meta.tags(types.ItemActionSound)) |item_action| {
        try reportAsset(allocator, &report, cwd, persistent_dir, io, .{
            .path = try std.fmt.allocPrint(allocator, "assets/audio/sfx/items/{s}_layer", .{@tagName(item_action)}),
            .description = itemActionDescription(item_action),
        }, &counts);
    }

    try cwd.writeFile(io, .{
        .sub_path = "sound_report.md",
        .data = report.items,
    });
    std.debug.print(
        "sound_report.md written: {d} shipped, {d} shadowed, {d} missing\n",
        .{ counts.shipped, counts.shadowed, counts.missing },
    );
}

/// Append one asset row with its resolved status, bumping the counters.
fn reportAsset(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
    cwd: std.Io.Dir,
    persistent_dir: ?std.Io.Dir,
    io: std.Io,
    asset: SoundAsset,
    counts: *ReportCounts,
) !void {
    const status = assetStatus(io, cwd, persistent_dir, asset.path);
    if (status.shipped_ext != null) counts.shipped += 1;
    if (status.shadowed_ext != null) counts.shadowed += 1;
    if (status.shipped_ext == null and status.shadowed_ext == null) counts.missing += 1;
    const status_text = try statusString(allocator, status);
    try report.print(allocator, "- `{s}` - {s} **[{s}]**\n", .{
        asset.path,
        asset.description,
        status_text,
    });
}

/// The report row's status text: `shipped (.ogg)`, `shadowed (.wav)`,
/// both (shadow wins), or `MISSING (silent)` - the extensions show WHICH
/// file resolves, since `.wav` and `.ogg` are both accepted.
fn statusString(allocator: std.mem.Allocator, status: AssetStatus) ![]const u8 {
    if (status.shipped_ext == null and status.shadowed_ext == null)
        return "MISSING (silent)";
    if (status.shipped_ext) |shipped_ext| {
        if (status.shadowed_ext) |shadowed_ext| {
            return std.fmt.allocPrint(
                allocator,
                "shipped ({s}) + shadowed ({s}) - shadow wins",
                .{ shipped_ext, shadowed_ext },
            );
        }
        return std.fmt.allocPrint(allocator, "shipped ({s})", .{shipped_ext});
    }
    return std.fmt.allocPrint(
        allocator,
        "shadowed ({s})",
        .{status.shadowed_ext.?},
    );
}

/// Probe each source for `path_without_extension` in the runtime lookup
/// order (`.wav` first) and record which extension resolved where.
fn assetStatus(
    io: std.Io,
    cwd: std.Io.Dir,
    persistent_dir: ?std.Io.Dir,
    path_without_extension: []const u8,
) AssetStatus {
    var status: AssetStatus = .{};
    if (foundExtension(io, cwd, path_without_extension)) |extension| {
        status.shipped_ext = extension;
    }
    if (persistent_dir) |dir| {
        if (foundExtension(io, dir, path_without_extension)) |extension| {
            status.shadowed_ext = extension;
        }
    }
    return status;
}

/// The first accepted extension of `path_without_extension` that exists in
/// `dir`, or null. Any stat error counts as "not there" (the report
/// degrades, never crashes - the `fileExists` discipline).
fn foundExtension(
    io: std.Io,
    dir: std.Io.Dir,
    path_without_extension: []const u8,
) ?[]const u8 {
    for (audio_extensions) |extension| {
        var buffer: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}{s}", .{
            path_without_extension,
            extension,
        }) catch continue;
        _ = dir.statFile(io, path, .{}) catch continue;
        return extension;
    }
    return null;
}

/// The per-OS persistent data directory: the SHARED resolution site
/// (persistent_path.zig - the same fn native.zig rides, so the default
/// exists once), fed from the environment. The tool reads `$TAPLOP_DATA`
/// or the platform default. libc is linked (see build.zig), so
/// `std.c.getenv` is available - the native.zig discipline.
fn resolvePersistentPath(allocator: std.mem.Allocator) ![]u8 {
    return persistent_path.resolvePersistentPath(
        allocator,
        @import("builtin").target.os.tag,
        .{
            .taplop_data = getenvSlice("TAPLOP_DATA"),
            .home = getenvSlice("HOME"),
            .xdg_data_home = getenvSlice("XDG_DATA_HOME"),
            .localappdata = getenvSlice("LOCALAPPDATA"),
            .userprofile = getenvSlice("USERPROFILE"),
        },
    );
}

/// getenv as a proper slice (NUL stripped); null when unset.
fn getenvSlice(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

/// Whether a `SoundId` is a layered-cue BASE (vs a plain one-shot) - splits
/// the report's SoundId walk into the two sections.
fn isBase(sound: types.SoundId) bool {
    return switch (sound) {
        .weapon_base,
        .spell_base,
        .cantrip_base,
        .enchantment_base,
        .curse_base,
        .item_base,
        .button_base_down,
        .button_base_up,
        => true,
        else => false,
    };
}

/// What each base plays on. THE doc for base semantics (single place).
fn baseDescription(sound: types.SoundId) []const u8 {
    return switch (sound) {
        .weapon_base => "every weapon-skill cast",
        .spell_base => "every spell cast",
        .cantrip_base => "every cantrip cast",
        .enchantment_base => "every enchantment cast",
        .curse_base => "every curse cast",
        .item_base => "every equip / salvage / learn / upgrade action",
        .button_base_down => "every button press (never layered)",
        .button_base_up => "every button release, except skill slots",
        else => "",
    };
}

/// What each one-shot plays on. THE doc for one-shot semantics (single
/// place).
fn oneShotDescription(sound: types.SoundId) []const u8 {
    return switch (sound) {
        .move => "every entity move (player + enemies)",
        .damage => "every attack that lands (per hit)",
        .collision => "a knockback slams the target into something",
        .pickup => "items picked up from the ground",
        .swap_skill => "utility-skill slot drag-swap (the skills panel)",
        .defeat => "the player dies",
        .mission_completion => "the final level of a mission completes",
        .heal => "a heal is applied",
        .stun => "a stun takes effect",
        .knockback => "a knockback pushes the target",
        .retreat => "a forced retreat pushes the target back",
        .death => "an enemy dies",
        .level_complete => "a non-final level completes",
        .aggro => "an enemy notices you (per newly-aggro'd enemy)",
        else => "",
    };
}

/// What each item-action layer plays on.
fn itemActionDescription(item_action: types.ItemActionSound) []const u8 {
    return switch (item_action) {
        .equip => "an item is equipped",
        .salvage => "an item is salvaged",
        .learn_skill => "a skill tome is learned",
        .upgrade => "an item stat is upgraded (hub vendor purchase)",
    };
}
