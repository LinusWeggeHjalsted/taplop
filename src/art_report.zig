//! Art asset overview generator - a build tool, never part of the game.
//! `zig build art-report` (wrapped by scripts/art_report.sh) enumerates every
//! sprite id the game can consume and writes art_report.md at the project
//! root: per-id status (shipped / shadowed / MISSING-draws-magenta) plus
//! the shipped sprites no shipped content references - entity/decoration
//! sprites are editor palette stock BY DESIGN (every shipped sprite is
//! player-placeable), so unreferenced is not unused. Three machine-walked
//! sources, so new
//! consumption appears automatically - no hand-maintained list to drift:
//!   1. The engine's enums + derivation shapes (skills via ui's
//!      skillIconSpriteId, effect overlays via the definitions' effect_sprite,
//!      items via the Item/WeaponType tags - a mirror of ui's
//!      itemIconSpriteId closed set - and weapons via WeaponType - a mirror
//!      of view.zig's `weapons/{enemy_}?<type>` derivation).
//!   2. Every sprite-id string literal in shipped code under src/ (the
//!      tool's own file excluded; test blocks excluded - fixture ids are
//!      structure-asserted, never loaded, and would put phantom assets on
//!      the shopping list).
//!   3. Every `sprite <stem>` reference in shipped data (levels, hubs,
//!      decorations.txt, editor defaults), mapped by section: Entities ->
//!      entities/, Decorations -> decorations/. (NPCs author `npc_type`,
//!      never a sprite - the NpcType enum walk in Source 1 covers their
//!      art.)
//! Plus one hand-maintained note that is not machine-derivable today -
//! see `manual_notes`. See DESIGN → Testing for why enum/table walks beat
//! coverage matrices; the sound_report.zig pattern throughout.

const std = @import("std");
const types = @import("types.zig");
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");

/// The sprite namespaces the game consumes - the first path segment of a
/// sprite id. Everything else under assets/ (audio, fonts) is not a sprite.
const sprite_namespaces = [_][]const u8{
    "entities", "weapons", "items", "skills", "effects", "npcs", "decorations", "ui", "world",
};

/// One consumed sprite id + where the consumption comes from (the report's
/// description column).
const ConsumedEntry = struct {
    id: []const u8,
    description: []const u8,
};

/// Tally of the reported statuses (the tool's stdout summary line).
const ReportCounts = struct {
    shipped: usize = 0,
    shadowed: usize = 0,
    missing: usize = 0,
    orphaned: usize = 0,
};

/// Hand-maintained notes the scanners cannot derive. Each entry retires when
/// its condition lands (the note says which).
const manual_notes = [_][]const u8{
    \\`ui/icon_undo` serves double duty as the redo button's glyph (drawn
    \\flipped); a future `ui/icon_redo` replaces it, at which point this note
    \\and the code alias both retire. Until then `ui/icon_redo` correctly does
    \\not appear as consumed.
,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();

    const persistent_path = try resolvePersistentPath(allocator);
    const persistent_dir: ?std.Io.Dir = cwd.openDir(io, persistent_path, .{
        .access_sub_paths = true,
    }) catch null;
    defer if (persistent_dir) |dir| std.Io.Dir.close(dir, io);

    // Deduped consumed-id table; first add wins, so the enum walks (run
    // first, with real descriptions) beat the raw literal scan.
    var consumed: std.StringArrayHashMapUnmanaged(ConsumedEntry) = .empty;

    // === Source 1: the engine's enums + derivation shapes ===
    for (std.meta.tags(types.SkillId)) |skill_id| {
        try addConsumed(&consumed, allocator, ui.skillIconSpriteId(skill_id), "skill icon (palette, buttons, tooltips)");
    }
    for (std.meta.tags(types.EffectId)) |effect_id| {
        const definition = lookups.getEffectDefinition(effect_id);
        if (definition.effect_sprite) |sprite| {
            const id = try std.fmt.allocPrint(allocator, "effects/{s}", .{sprite});
            try addConsumed(&consumed, allocator, id, "world overlay for the effect");
        }
        // The UI icon (ui.effectIconSpriteId) is either the caster skill's
        // icon (already covered by the SkillId walk), this same effects/<x>
        // overlay id, or the definition's display name (not a sprite id) -
        // nothing new to add, so it is not called.
    }
    const ItemTag = @typeInfo(types.Item).@"union".tag_type.?;
    for (std.meta.tags(ItemTag)) |item_tag| {
        if (item_tag == .weapon) {
            for (std.meta.tags(types.WeaponType)) |weapon_type| {
                const id = try std.fmt.allocPrint(allocator, "items/{s}", .{@tagName(weapon_type)});
                try addConsumed(&consumed, allocator, id, "weapon item icon");
            }
        } else {
            const id = try std.fmt.allocPrint(allocator, "items/{s}", .{@tagName(item_tag)});
            try addConsumed(&consumed, allocator, id, "item icon");
        }
    }
    for (std.meta.tags(types.WeaponType)) |weapon_type| {
        const id = try std.fmt.allocPrint(allocator, "weapons/{s}", .{@tagName(weapon_type)});
        try addConsumed(&consumed, allocator, id, "player body + weapon art (team 0 uses the plain art)");
        const enemy_id = try std.fmt.allocPrint(allocator, "weapons/enemy_{s}", .{@tagName(weapon_type)});
        try addConsumed(&consumed, allocator, enemy_id, "enemy weapon art (the enemy_ variant)");
    }
    for (std.meta.tags(types.NpcType)) |npc_type| {
        try addConsumed(&consumed, allocator, npc_type.spriteId(), "hub NPC sprite (derives from the type - hub files author npc_type, never a sprite)");
    }

    // === Source 2: sprite-id string literals under src/ ===
    {
        var zig_files: std.ArrayList([]const u8) = .empty;
        try walkFiles(allocator, io, cwd, "src", ".zig", &zig_files);
        for (zig_files.items) |path| {
            // The tool's own literals (manual_notes) would self-report.
            if (std.mem.eql(u8, path, "src/art_report.zig")) continue;
            const bytes = cwd.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch continue;
            try scanSourceLiterals(&consumed, allocator, bytes, path);
        }
    }

    // === Source 3: `sprite <stem>` references in shipped data ===
    {
        var data_files: std.ArrayList([]const u8) = .empty;
        try walkFiles(allocator, io, cwd, "data", ".txt", &data_files);
        for (data_files.items) |path| {
            const bytes = cwd.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch continue;
            try scanDataSpriteLines(&consumed, allocator, bytes, path);
        }
    }

    // === Shipped inventory (for the orphan pass) ===
    var shipped_ids: std.ArrayList([]const u8) = .empty;
    {
        var png_files: std.ArrayList([]const u8) = .empty;
        try walkFiles(allocator, io, cwd, "assets", ".png", &png_files);
        for (png_files.items) |path| {
            if (!std.mem.startsWith(u8, path, "assets/")) continue;
            const id = stripPrefixSuffix(path, "assets/", ".png") orelse continue;
            if (idNamespace(id) == null) continue;
            try shipped_ids.append(allocator, id);
        }
    }

    // === Report assembly ===
    var report: std.ArrayList(u8) = .empty;
    var counts: ReportCounts = .{};

    try report.print(allocator,
        \\# Ziglop art asset overview
        \\
        \\Auto-generated from the engine's enums, the source tree's sprite-id
        \\literals, and the shipped content's `sprite` references - every
        \\sprite id the game can consume, with status. Regenerate with
        \\`scripts/art_report.sh`.
        \\
        \\**How to add or replace art:** drop a PNG at
        \\`{s}/assets/<id>.png` - the persistent directory overrides the
        \\shipped copy (asset shadowing) and is checked at every launch. Or
        \\place it in the repo's `assets/` tree (shipped) - the game embeds
        \\assets at BUILD time, so a repo copy needs a rebuild to show up.
        \\
        \\**Missing = magenta.** A missing sprite draws a magenta placeholder
        \\at its destination rect (no fallbacks), so the status column is the
        \\complete truth about what is done and what is missing.
        \\
        \\Included consumption sources: engine enums + derivations (skills,
        \\effects, items, weapons), every sprite-id string literal in shipped
        \\code (test blocks excluded - fixture ids are not game consumption),
        \\and every `sprite <stem>` reference in shipped data (levels/hubs/
        \\decorations/editor defaults, mapped by section: Entities ->
        \\entities/, Decorations -> decorations/; NPC art derives from the
        \\NpcType enum walk above).
        \\
        \\Hand-maintained notes (each retires when its condition lands):
        \\
    , .{persistent_path});
    for (manual_notes) |note| {
        try report.print(allocator, "- {s}\n", .{note});
    }

    // The shopping list first: every MISSING id across all namespaces.
    try report.print(allocator, "\n## MISSING - the shopping list\n\n", .{});
    var missing_count: usize = 0;
    for (sprite_namespaces) |namespace| {
        for (consumedIdsIn(&consumed, allocator, namespace)) |entry| {
            const status = assetStatus(io, cwd, persistent_dir, entry.id);
            if (status.shipped == null and status.shadowed == null) {
                counts.missing += 1;
                missing_count += 1;
                try report.print(allocator, "- `assets/{s}.png` - {s} **[MISSING (draws magenta)]**\n", .{
                    entry.id, entry.description,
                });
            }
        }
    }
    if (missing_count == 0) {
        try report.print(allocator, "- (nothing missing - every consumed id resolves)\n", .{});
    }

    // Per-namespace sections: every consumed id with its status.
    for (sprite_namespaces) |namespace| {
        const entries = consumedIdsIn(&consumed, allocator, namespace);
        if (entries.len == 0) continue;
        try report.print(allocator, "\n## {s} ({d} consumed)\n\n", .{ namespace, entries.len });
        for (entries) |entry| {
            try reportAsset(allocator, &report, io, cwd, persistent_dir, entry, &counts);
        }
    }

    // Shipped but unreferenced by shipped content: entity/decoration
    // sprites are editor palette stock BY DESIGN (every shipped sprite is
    // player-placeable), so unreferenced is not unused.
    try report.print(allocator, "\n## Shipped but unreferenced by shipped content\n\n", .{});
    try report.print(allocator,
        \\Entity + decoration sprites are editor palette stock BY DESIGN -
        \\every shipped sprite is player-placeable in the editor, so
        \\unreferenced is NOT unused: this section tracks what the official
        \\campaign does not use yet (real content authoring rides the campaign
        \\editor). Other namespaces here are genuinely unreferenced.
        \\
    , .{});
    var orphan_count: usize = 0;
    for (sprite_namespaces) |namespace| {
        var namespace_orphans: std.ArrayList([]const u8) = .empty;
        for (shipped_ids.items) |id| {
            if (!std.mem.eql(u8, idNamespace(id).?, namespace)) continue;
            if (consumed.contains(id)) continue;
            try namespace_orphans.append(allocator, id);
        }
        if (namespace_orphans.items.len == 0) continue;
        orphan_count += namespace_orphans.items.len;
        try report.print(allocator, "\n**{s}:**\n\n", .{namespace});
        for (namespace_orphans.items) |id| {
            try report.print(allocator, "- `assets/{s}.png` - shipped, not referenced by shipped content (editor palette stock)\n", .{id});
        }
    }
    if (orphan_count == 0) {
        try report.print(allocator, "- (every shipped sprite is referenced by shipped content)\n", .{});
    }

    counts.orphaned = orphan_count;
    try cwd.writeFile(io, .{
        .sub_path = "art_report.md",
        .data = report.items,
    });
    std.debug.print(
        "art_report.md written: {d} shipped, {d} shadowed, {d} missing, {d} unreferenced (editor palette stock)\n",
        .{ counts.shipped, counts.shadowed, counts.missing, counts.orphaned },
    );
}

/// Add a consumed id unless it is already in the table (first add wins -
/// the enum walks run first so their descriptions beat the raw scans).
fn addConsumed(
    consumed: *std.StringArrayHashMapUnmanaged(ConsumedEntry),
    allocator: std.mem.Allocator,
    id: []const u8,
    description: []const u8,
) !void {
    if (consumed.contains(id)) return;
    try consumed.put(allocator, id, .{
        .id = id,
        .description = description,
    });
}

/// Append one asset row with its resolved status, bumping the counters.
fn reportAsset(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
    io: std.Io,
    cwd: std.Io.Dir,
    persistent_dir: ?std.Io.Dir,
    entry: ConsumedEntry,
    counts: *ReportCounts,
) !void {
    const status = assetStatus(io, cwd, persistent_dir, entry.id);
    const status_text: []const u8 = if (status.shipped != null and status.shadowed != null)
        "shipped + shadowed - shadow wins"
    else if (status.shipped != null)
        "shipped"
    else if (status.shadowed != null)
        "shadowed (persistent-dir override)"
    else
        "MISSING (draws magenta)";
    if (status.shipped != null) counts.shipped += 1;
    if (status.shadowed != null) counts.shadowed += 1;
    try report.print(allocator, "- `assets/{s}.png` - {s} **[{s}]**\n", .{
        entry.id, entry.description, status_text,
    });
}

/// Whether `assets/<id>.png` exists in the shipped tree and/or the
/// persistent-dir shadow (which mirrors the full project-relative path).
const AssetStatus = struct {
    shipped: ?void,
    shadowed: ?void,
};

fn assetStatus(
    io: std.Io,
    cwd: std.Io.Dir,
    persistent_dir: ?std.Io.Dir,
    id: []const u8,
) AssetStatus {
    var buffer: [512]u8 = undefined;
    const shipped_path = std.fmt.bufPrint(&buffer, "assets/{s}.png", .{id}) catch unreachable;
    const shipped: ?void = if (isFile(io, cwd, shipped_path)) {} else null;
    var shadowed: ?void = null;
    if (persistent_dir) |dir| {
        if (isFile(io, dir, shipped_path)) shadowed = {};
    }
    return .{ .shipped = shipped, .shadowed = shadowed };
}

fn isFile(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

/// Scan source bytes for quoted string literals that are sprite ids (a
/// namespace prefix + [a-z0-9_] stem). Literal consumption is the truth for
/// the UI/world icon set - there is no enum to walk. Test blocks are
/// EXCLUDED (they are not game consumption: a test's fixture ids are
/// structure-asserted, never loaded - reporting them would put phantom
/// assets on the shopping list, the custom_fighter/moss_vine class). Zig
/// source is zig-fmt'd, so the exclusion is exact: test declarations are
/// top-level (`test ...` at column 0) and their block closes with a lone
/// `}` at column 0.
fn scanSourceLiterals(
    consumed: *std.StringArrayHashMapUnmanaged(ConsumedEntry),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    path: []const u8,
) !void {
    var skipping_test_block = false;
    var line_iterator = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iterator.next()) |line| {
        if (skipping_test_block) {
            if (std.mem.eql(u8, line, "}")) skipping_test_block = false;
            continue;
        }
        if (std.mem.startsWith(u8, line, "test ")) {
            skipping_test_block = true;
            continue;
        }
        try scanLineLiterals(consumed, allocator, line, path);
    }
}

fn scanLineLiterals(
    consumed: *std.StringArrayHashMapUnmanaged(ConsumedEntry),
    allocator: std.mem.Allocator,
    line: []const u8,
    path: []const u8,
) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] != '"') {
            i += 1;
            continue;
        }
        const start = i + 1;
        var end = start;
        while (end < line.len and line[end] != '"' and line[end] != '\n') end += 1;
        if (end >= line.len or line[end] != '"') {
            i = start;
            continue;
        }
        const literal = line[start..end];
        if (idNamespace(literal) != null) {
            const description = try std.fmt.allocPrint(allocator, "code-referenced ({s})", .{path});
            try addConsumed(consumed, allocator, literal, description);
        }
        i = end + 1;
    }
}

/// Scan data bytes for `sprite <stem>` lines, mapping the stem to its
/// namespace by the current section header (Entities/Decorations - the
/// parser's section model). Mirrors the loaders' namespace derivation.
fn scanDataSpriteLines(
    consumed: *std.StringArrayHashMapUnmanaged(ConsumedEntry),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    path: []const u8,
) !void {
    var section: []const u8 = "";
    var line_iterator = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iterator.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\n");
        if (isSectionHeader(line)) {
            section = line;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "sprite ")) continue;
        const stem = std.mem.trim(u8, line["sprite ".len..], " ");
        if (stem.len == 0 or !isStem(stem)) continue;
        const namespace: ?[]const u8 = if (std.mem.eql(u8, section, "Entities"))
            "entities"
        else if (std.mem.eql(u8, section, "Decorations"))
            "decorations"
        else
            null;
        if (namespace == null) continue;
        const id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ namespace.?, stem });
        const description = try std.fmt.allocPrint(allocator, "content-referenced ({s})", .{path});
        try addConsumed(consumed, allocator, id, description);
    }
}

/// A section header line: a single CamelCase word (the config format - see
/// parser.zig). Length-gated so a lone grid letter can't pose as one.
fn isSectionHeader(line: []const u8) bool {
    if (line.len < 4) return false;
    for (line, 0..) |char, index| {
        if (char < 'A' or char > 'z' or (char > 'Z' and char < 'a')) return false;
        if (index == 0 and char >= 'a') return false;
    }
    return true;
}

fn isStem(stem: []const u8) bool {
    for (stem) |char| {
        if ((char < 'a' or char > 'z') and (char < '0' or char > '9') and char != '_') return false;
    }
    return true;
}

/// The namespace (first path segment) of a sprite id, or null if `id` is
/// not in a sprite namespace or is not id-shaped.
fn idNamespace(id: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    const namespace = id[0..slash];
    const stem = id[slash + 1 ..];
    if (stem.len == 0 or !isStem(stem)) return null;
    for (sprite_namespaces) |candidate| {
        if (std.mem.eql(u8, namespace, candidate)) return candidate;
    }
    return null;
}

/// All consumed entries whose id starts with `<namespace>/`, sorted by id -
/// the per-namespace report section + the MISSING walk.
fn consumedIdsIn(
    consumed: *std.StringArrayHashMapUnmanaged(ConsumedEntry),
    allocator: std.mem.Allocator,
    namespace: []const u8,
) []ConsumedEntry {
    var entries: std.ArrayList(ConsumedEntry) = .empty;
    var iterator = consumed.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.startsWith(u8, entry.value_ptr.id, namespace) and
            entry.value_ptr.id.len > namespace.len and
            entry.value_ptr.id[namespace.len] == '/')
        {
            entries.append(allocator, entry.value_ptr.*) catch @panic("OOM");
        }
    }
    std.mem.sort(ConsumedEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: ConsumedEntry, b: ConsumedEntry) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    return entries.items;
}

/// Recursively collect file paths under `dir_path` ending with `extension`.
/// Missing/unreadable directories are skipped (the report degrades, never
/// crashes - the `fileExists` discipline).
fn walkFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    dir_path: []const u8,
    extension: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch return) |entry| {
        // entry.name dies at the next iteration - allocPrint copies it.
        const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try walkFiles(allocator, io, cwd, child_path, extension, out),
            .file => {
                if (std.mem.endsWith(u8, entry.name, extension)) {
                    try out.append(allocator, child_path);
                }
            },
            else => {},
        }
    }
}

/// `path` minus `prefix` and `suffix`, or null if it doesn't carry both.
fn stripPrefixSuffix(path: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (!std.mem.endsWith(u8, path, suffix)) return null;
    const inner = path[prefix.len .. path.len - suffix.len];
    if (inner.len == 0) return null;
    return inner;
}

/// The per-OS persistent data directory (mirrors sound_report.zig's
/// resolvePersistentPath - the native.zig discipline, minus the CLI flag).
fn resolvePersistentPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("ZIGLOP_DATA")) |override| {
        return allocator.dupe(u8, std.mem.sliceTo(override, 0));
    }
    const home = std.c.getenv("HOME") orelse return error.HomeNotSet;
    const home_slice = std.mem.sliceTo(home, 0);
    return switch (@import("builtin").os.tag) {
        .macos => try std.fmt.allocPrint(
            allocator,
            "{s}/Library/Application Support/ziglop",
            .{home_slice},
        ),
        else => try std.fmt.allocPrint(allocator, "{s}/.ziglop", .{home_slice}),
    };
}
