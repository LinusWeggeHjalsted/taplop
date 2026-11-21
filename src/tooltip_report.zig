//! Tooltip text report generator - a build tool, never part of the game.
//! `zig build tooltip-report` (wrapped by scripts/tooltip_report.sh) writes
//! `tooltip_report.md` at the project root: every piece of tooltip text the
//! game can show, for wording review in one place. Two parts, from two
//! kinds of source truth:
//!   1. DATA-DRIVEN content - the game's real builders (buildSkillTooltip
//!      / buildEffectTooltip / buildItemTooltip / emitMaterialIcons) walked
//!      over their enums with example values. Enum-keyed: new skills or
//!      effects appear automatically - no hand-maintained list to drift.
//!   2. LITERAL emission sites - every `.tooltip = ` initializer under
//!      src/, with the string literals inside it (format placeholders
//!      like `{d}` stay as placeholders). Extraction is best-effort over
//!      a COMPLETE site inventory: a site whose text is built at runtime
//!      lists with its expression so nothing is invisible.
//! Test blocks are excluded (fixture text is not shipped text - the
//! art_report scanner's convention). See DESIGN → UI Framework (the
//! tooltip content model).

const std = @import("std");
const types = @import("types.zig");
const lookups = @import("generated_lookups.zig");
const ui = @import("ui.zig");
const element = @import("ui/element.zig");

const Tooltip = element.Tooltip;
const UiElementList = element.UiElementList;

/// One literal emission site: a `.tooltip = ` initializer occurrence with
/// its extracted literals (empty when the text is built at runtime - the
/// expression is reported instead). `runtime_expression` and the literal
/// slices point into the source bytes (arena-owned for the tool's run).
const TooltipSite = struct {
    path: []const u8,
    line: usize,
    literals: []const []const u8,
    runtime_expression: ?[]const u8 = null,
    /// For variable-built sites: the format string of the `allocPrint`
    /// that fed the variable (the medals' "{s} Medal - {d} turns" class -
    /// the format lives BEFORE the initializer, out of the brace region).
    /// Best-effort: only a plain `text(<identifier>)` with a matching
    /// `<identifier> = try std.fmt.allocPrint(` above the site resolves.
    feeding_format_literal: ?[]const u8 = null,
};

/// A one-line-per-row plain-text rendering of a tooltip (span styling
/// dropped - the wording is the report's subject).
fn appendTooltipText(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
    tooltip: Tooltip,
) !void {
    if (tooltip.header) |header| {
        try report.print(allocator, "  {s}\n", .{concatenatedSpans(allocator, header)});
    }
    for (tooltip.body) |row| {
        try report.print(allocator, "  {s}\n", .{concatenatedSpans(allocator, row)});
    }
}

/// A row's spans joined into one plain string (no separators - the
/// builders already space their spans).
fn concatenatedSpans(allocator: std.mem.Allocator, row: element.TooltipRow) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (row) |span| {
        out.appendSlice(allocator, span.text) catch
            @panic("failed to build the report row");
    }
    return out.items;
}

/// One example item per weapon type (damage 5 - a mid value inside the
/// balance bounds), no equipped baseline (the plain "Damage 5" shape).
fn appendExampleWeaponRows(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
) !void {
    for (std.meta.tags(types.WeaponType)) |weapon_type| {
        const name = try std.fmt.allocPrint(allocator, "Example {s}", .{@tagName(weapon_type)});
        const item = types.Item{ .weapon = .{
            .name = name,
            .weapon_type = weapon_type,
            .weapon_damage = 5,
        } };
        const tooltip = try ui.buildItemTooltip(allocator, item, &.{}, null);
        try report.print(allocator, "- {s} ({s})\n", .{ name, @tagName(weapon_type) });
        try appendTooltipText(allocator, report, tooltip);
    }
}

/// The comparison vocabulary: the same example weapon against BOTH
/// equipped hands (main 4, off 6) shows the "Label value (+1, -1)"
/// comparison shape every inventory tooltip can carry.
fn appendComparisonWeaponRows(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
) !void {
    const item = types.Item{ .weapon = .{
        .name = "Example sword",
        .weapon_type = .sword,
        .weapon_damage = 5,
    } };
    const equipped = ui.EquippedGear{
        .main_hand_weapon = .{ .name = "Main hand", .weapon_type = .sword, .weapon_damage = 4 },
        .off_hand_weapon = .{ .name = "Off hand", .weapon_type = .sword, .weapon_damage = 6 },
    };
    const tooltip = try ui.buildItemTooltip(allocator, item, &.{}, equipped);
    try report.print(allocator, "- Example sword (vs both equipped hands - the comparison shape)\n", .{});
    try appendTooltipText(allocator, report, tooltip);
}

/// One example per gear shape (stat labels are the wording under review;
/// the values are plausible mid-range examples).
fn appendExampleGearRows(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
) !void {
    const gear = [_]types.Item{
        .{ .amulet = .{ .name = "Example amulet", .spell_damage = 2 } },
        .{ .coat = .{ .name = "Example coat", .health_bonus = 3, .defense_bonus = 2 } },
        .{ .gloves = .{ .name = "Example gloves", .health_bonus = 1, .damage_bonus = 2 } },
        .{ .pants = .{ .name = "Example pants", .health_bonus = 1, .pickup_radius_bonus = 2 } },
        .{ .boots = .{ .name = "Example boots", .health_bonus = 1, .speed_bonus = 1 } },
    };
    for (gear) |item| {
        const tooltip = try ui.buildItemTooltip(allocator, item, &.{}, null);
        const name = switch (item) {
            .amulet => |amulet| amulet.name,
            .coat => |coat| coat.name,
            .gloves => |gloves| gloves.name,
            .pants => |pants| pants.name,
            .boots => |boots| boots.name,
            else => unreachable,
        };
        try report.print(allocator, "- {s}\n", .{name});
        try appendTooltipText(allocator, report, tooltip);
    }
}

/// A skill tome both ways: unlearned (the learn prompt) + already
/// learned.
fn appendExampleTomeRows(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
) !void {
    const tome = types.Item{ .skill_tome = .{ .skill = .slice, .value = 5 } };
    {
        const tooltip = try ui.buildItemTooltip(allocator, tome, &.{}, null);
        try report.print(allocator, "- Skill tome (not yet learned)\n", .{});
        try appendTooltipText(allocator, report, tooltip);
    }
    {
        const tooltip = try ui.buildItemTooltip(allocator, tome, &.{types.SkillId.slice}, null);
        try report.print(allocator, "- Skill tome (already learned)\n", .{});
        try appendTooltipText(allocator, report, tooltip);
    }
}

/// The material count rows ("N wood"...) harvested by calling the REAL
/// icon emitter with example counts and reading the emitted elements'
/// tooltips back - no re-derivation to drift.
fn appendMaterialCountRows(
    allocator: std.mem.Allocator,
    report: *std.ArrayList(u8),
) !void {
    const metrics = element.FontMetrics{ .base_size = 100, .advances = @as([95]i32, @splat(50)) };
    const theme = types.ActiveColorTheme{
        .lightest = .{ .r = 255, .g = 255, .b = 255 },
        .darkest = .{ .r = 0, .g = 0, .b = 0 },
        .world_gradient = .{ .colors = @as([6]types.Color, @splat(.{ .r = 0, .g = 0, .b = 0 })) },
        .enemy_gradient = .{ .colors = @as([6]types.Color, @splat(.{ .r = 0, .g = 0, .b = 0 })) },
        .player_gradient = .{ .colors = @as([6]types.Color, @splat(.{ .r = 0, .g = 0, .b = 0 })) },
    };
    const example_materials = types.Materials{
        .wood = 4,
        .metal = 12,
        .leather = 1,
        .cloth = 0,
        .knowledge = 2,
    };
    var harvested: UiElementList = .empty;
    try ui.emitMaterialIcons(
        &harvested,
        allocator,
        metrics,
        .{ .x = 0, .y = 0 },
        64,
        .horizontal,
        example_materials,
        theme,
    );
    for (harvested.items) |harvested_element| switch (harvested_element) {
        .image => |image| {
            const tooltip = image.tooltip orelse continue;
            const header = tooltip.header orelse continue;
            try report.print(allocator, "- {s}\n", .{concatenatedSpans(allocator, header)});
        },
        else => {},
    };
}

/// The line-start offsets of every line in `bytes` (line numbers are
/// 1-based; a binary search over this finds an offset's line).
fn lineStarts(allocator: std.mem.Allocator, bytes: []const u8) ![]const usize {
    var starts: std.ArrayList(usize) = .empty;
    try starts.append(allocator, 0);
    for (bytes, 0..) |byte, index| {
        if (byte == '\n') try starts.append(allocator, index + 1);
    }
    return starts.toOwnedSlice(allocator);
}

/// Whether each 1-based line is inside a `test` block (zig-fmt'd source
/// makes the boundaries exact: blocks open with a column-0 `test ` line
/// and close with a lone column-0 `}`). Fixture text is not shipped text.
fn testBlockLines(allocator: std.mem.Allocator, bytes: []const u8) ![]const bool {
    var flags: std.ArrayList(bool) = .empty;
    var skipping = false;
    var line_iterator = std.mem.splitScalar(u8, bytes, '\n');
    while (line_iterator.next()) |line| {
        if (skipping) {
            if (std.mem.eql(u8, line, "}")) skipping = false;
            try flags.append(allocator, true);
            continue;
        }
        if (std.mem.startsWith(u8, line, "test ")) {
            skipping = true;
            try flags.append(allocator, true);
            continue;
        }
        try flags.append(allocator, false);
    }
    return flags.toOwnedSlice(allocator);
}

/// The 1-based line number containing `offset` (a linear cursor over
/// `starts` - callers scan forward, so this stays O(total)).
fn lineNumberForOffset(starts: []const usize, offset: usize) usize {
    var line: usize = 1;
    while (line < starts.len and starts[line] <= offset) line += 1;
    return line;
}

/// Collect the `.tooltip = ` initializer sites in one source file's bytes:
/// for each occurrence, either the string literals inside the
/// `.{ ... }` initializer (braces balanced through string literals so
/// `{d}` placeholders don't confuse the depth count) or, when the text is
/// built at runtime, the RHS expression up to the line end. Occurrences
/// inside test blocks are skipped (the art_report scanner's convention).
fn scanTooltipSites(
    sites: *std.ArrayList(TooltipSite),
    allocator: std.mem.Allocator,
    bytes: []const u8,
    path: []const u8,
) !void {
    const starts = try lineStarts(allocator, bytes);
    const test_lines = try testBlockLines(allocator, bytes);
    const marker = ".tooltip = ";
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search_from, marker)) |occurrence| {
        search_from = occurrence + marker.len;
        const line = lineNumberForOffset(starts, occurrence);
        if (line - 1 < test_lines.len and test_lines[line - 1]) continue;

        var cursor = occurrence + marker.len;
        while (cursor < bytes.len and bytes[cursor] == ' ') cursor += 1;
        if (cursor + 1 < bytes.len and bytes[cursor] == '.' and bytes[cursor + 1] == '{') {
            const initializer = try collectInitializerLiterals(allocator, bytes, cursor + 1);
            if (initializer.len == 0) {
                // No literals inside: the text comes from a variable or a
                // call - report the initializer's first line so the reader
                // can locate it (the variable-built class, same as the
                // non-inline assignments below), plus the feeding
                // allocPrint's format when the variable resolves.
                const open_brace = cursor + 1;
                const line_end = std.mem.indexOfScalarPos(u8, bytes, open_brace, '\n') orelse bytes.len;
                const expression = std.mem.trim(u8, bytes[open_brace..line_end], " },");
                try sites.append(allocator, .{
                    .path = path,
                    .line = line,
                    .literals = &.{},
                    .runtime_expression = expression,
                    .feeding_format_literal = feedingAllocPrintFormat(allocator, bytes, occurrence, expression),
                });
            } else {
                try sites.append(allocator, .{
                    .path = path,
                    .line = line,
                    .literals = initializer,
                });
            }
        } else {
            const line_end = std.mem.indexOfScalarPos(u8, bytes, cursor, '\n') orelse bytes.len;
            const expression = std.mem.trim(u8, bytes[cursor..line_end], " ,");
            try sites.append(allocator, .{
                .path = path,
                .line = line,
                .literals = &.{},
                .runtime_expression = expression,
                .feeding_format_literal = feedingAllocPrintFormat(allocator, bytes, occurrence, expression),
            });
        }
    }
}

/// The string literals inside the brace initializer starting at
/// `open_brace_index` (the `{` itself), balanced through nested braces;
/// string escapes are skipped so `\"` and `{d}` cannot confuse the scan.
fn collectInitializerLiterals(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    open_brace_index: usize,
) ![]const []const u8 {
    var literals: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var index = open_brace_index;
    while (index < bytes.len) : (index += 1) {
        switch (bytes[index]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) break;
            },
            '"' => {
                var end = index + 1;
                while (end < bytes.len) : (end += 1) {
                    if (bytes[end] == '\\') {
                        end += 1;
                        continue;
                    }
                    if (bytes[end] == '"') break;
                }
                // An @import("...") path inside the region is a module
                // name, not tooltip text.
                if (!precededByImportCall(bytes, index)) {
                    try literals.append(allocator, bytes[index + 1 .. @min(end, bytes.len)]);
                }
                index = end;
            },
            '\'' => {
                var end = index + 1;
                while (end < bytes.len) : (end += 1) {
                    if (bytes[end] == '\\') {
                        end += 1;
                        continue;
                    }
                    if (bytes[end] == '\'') break;
                }
                index = end;
            },
            else => {},
        }
    }
    return literals.toOwnedSlice(allocator);
}

/// The format string of the `allocPrint` feeding a variable-built
/// tooltip, or null. Only the precise shape resolves: `expression`
/// contains `text(<identifier>)` with a plain identifier, and a
/// `<identifier> = try std.fmt.allocPrint(` exists above `site_offset`
/// (the nearest such declaration wins; the search is whole-file so a
/// far-away false match is possible in principle - the report tags these
/// as formats, the site line stays the authority).
fn feedingAllocPrintFormat(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    site_offset: usize,
    expression: []const u8,
) ?[]const u8 {
    const text_call_index = std.mem.indexOf(u8, expression, "text(") orelse return null;
    var identifier = expression[text_call_index + "text(".len ..];
    const closing = std.mem.indexOfScalar(u8, identifier, ')') orelse return null;
    identifier = std.mem.trim(u8, identifier[0..closing], " ");
    // Only plain identifiers (a field path or call never resolves this
    // way).
    if (identifier.len == 0) return null;
    for (identifier) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_')) return null;
    }

    const declaration = std.fmt.allocPrint(allocator, "{s} = try std.fmt.allocPrint(", .{identifier}) catch
        @panic("failed to build the allocPrint search needle");
    var search_from: usize = 0;
    var found: ?usize = null;
    while (std.mem.indexOfPos(u8, bytes, search_from, declaration)) |declaration_index| {
        if (declaration_index >= site_offset) break;
        found = declaration_index;
        search_from = declaration_index + declaration.len;
    }
    const declaration_index = found orelse return null;

    // The format literal is inside the allocPrint call's parentheses -
    // balance through string literals so nested parens cannot confuse it.
    const open_paren = declaration_index + declaration.len - 1;
    var depth: usize = 0;
    var index = open_paren;
    while (index < bytes.len) : (index += 1) {
        switch (bytes[index]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) break;
            },
            '"' => {
                var end = index + 1;
                while (end < bytes.len) : (end += 1) {
                    if (bytes[end] == '\\') {
                        end += 1;
                        continue;
                    }
                    if (bytes[end] == '"') break;
                }
                const literal = bytes[index + 1 .. @min(end, bytes.len)];
                index = end;
                // The FIRST string literal in the call is the format.
                return literal;
            },
            else => {},
        }
    }
    return null;
}

/// Recursive `.zig` collection under `dir_path` (the art_report walker:
/// entry names are copied per iteration; unreadable dirs are skipped).
fn walkFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    dir_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch return) |entry| {
        const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try walkFiles(allocator, io, cwd, child_path, out),
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".zig")) {
                    try out.append(allocator, child_path);
                }
            },
            else => {},
        }
    }
}

/// Whether the string literal at `literal_start` is the argument of an
/// `@import(` call (skipped backwards over whitespace).
fn precededByImportCall(bytes: []const u8, literal_start: usize) bool {
    var index = literal_start;
    while (index > 0 and bytes[index - 1] == ' ') index -= 1;
    const import_call = "@import(";
    if (index < import_call.len) return false;
    return std.mem.eql(u8, bytes[index - import_call.len .. index], import_call);
}

fn siteOrder(_: void, first: TooltipSite, second: TooltipSite) bool {
    const path_order = std.mem.order(u8, first.path, second.path);
    if (path_order != .eq) return path_order == .lt;
    return first.line < second.line;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();
    const cwd = std.Io.Dir.cwd();

    var report: std.ArrayList(u8) = .empty;

    try report.print(allocator,
        \\# taplop tooltip text report
        \\
        \\Auto-generated - every tooltip the game can show, for wording review
        \\in one place. Regenerate with `scripts/tooltip_report.sh`.
        \\
        \\Two kinds of source truth:
        \\- Part 1 walks the game's REAL builders over their enums with
        \\  example values (new skills/effects appear automatically). Plain
        \\  text; span styling is dropped. Item names and stat values are
        \\  example data - the wording is the subject.
        \\- Part 2 lists every literal `.tooltip = ` emission site under
        \\  src/ with the string literals inside it. Format placeholders
        \\  (`{{d}}`, `{{s}}`) stay as placeholders; a site whose text is built
        \\  at runtime lists with its expression so nothing is invisible.
        \\
        \\## Part 1: data-driven content (the real builders, example values)
        \\
        \\### Skills (every SkillId through buildSkillTooltip)
        \\
        \\
    , .{});
    for (std.meta.tags(types.SkillId)) |skill_id| {
        const definition = lookups.getSkillDefinition(skill_id) orelse continue;
        const tooltip = try ui.buildSkillTooltip(allocator, definition);
        try report.print(allocator, "- {s} [{s}]\n", .{ definition.name, @tagName(skill_id) });
        try appendTooltipText(allocator, &report, tooltip);
    }

    try report.print(allocator,
        \\
        \\### Effects (every EffectId through buildEffectTooltip; duration example 3)
        \\
        \\
    , .{});
    for (std.meta.tags(types.EffectId)) |effect_id| {
        const definition = lookups.getEffectDefinition(effect_id);
        const tooltip = try ui.buildEffectTooltip(allocator, definition, 3);
        try report.print(allocator, "- {s} [{s}]\n", .{ definition.name, @tagName(effect_id) });
        try appendTooltipText(allocator, &report, tooltip);
    }

    try report.print(allocator,
        \\
        \\### Items (buildItemTooltip; names + values are example data)
        \\
        \\#### Weapons (every WeaponType)
        \\
        \\
    , .{});
    try appendExampleWeaponRows(allocator, &report);

    try report.print(allocator,
        \\
        \\#### The comparison shape (the same weapon vs both equipped hands)
        \\
        \\
    , .{});
    try appendComparisonWeaponRows(allocator, &report);

    try report.print(allocator,
        \\
        \\#### Gear (one per shape)
        \\
        \\
    , .{});
    try appendExampleGearRows(allocator, &report);

    try report.print(allocator,
        \\
        \\#### Skill tomes
        \\
        \\
    , .{});
    try appendExampleTomeRows(allocator, &report);

    try report.print(allocator,
        \\
        \\### Material counts (emitMaterialIcons' hover rows, example counts)
        \\
        \\
    , .{});
    try appendMaterialCountRows(allocator, &report);

    // ── Part 2: the literal emission sites. ──
    var sites: std.ArrayList(TooltipSite) = .empty;
    {
        var zig_files: std.ArrayList([]const u8) = .empty;
        try walkFiles(allocator, io, cwd, "src", &zig_files);
        for (zig_files.items) |path| {
            // The tool's own literals (this report's prose) would
            // self-report; test blocks are skipped per-file inside the
            // scanner.
            if (std.mem.eql(u8, path, "src/tooltip_report.zig")) continue;
            const bytes = cwd.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch continue;
            try scanTooltipSites(&sites, allocator, bytes, path);
        }
    }
    std.mem.sort(TooltipSite, sites.items, {}, siteOrder);

    try report.print(allocator,
        \\
        \\## Part 2: literal emission sites (every `.tooltip = ` under src/)
        \\
        \\Grouped by source file, line numbers are exact. Sites marked
        \\`(built at runtime)` produce their text in code - the Part 1
        \\builders cover the shared ones.
        \\
        \\
    , .{});
    var runtime_site_count: usize = 0;
    var current_path: ?[]const u8 = null;
    for (sites.items) |site| {
        if (current_path == null or !std.mem.eql(u8, current_path.?, site.path)) {
            current_path = site.path;
            try report.print(allocator, "### {s}\n\n", .{site.path});
        }
        if (site.runtime_expression) |expression| {
            runtime_site_count += 1;
            if (site.feeding_format_literal) |format| {
                try report.print(allocator, "- L{d}: \"{s}\" (format, built at runtime)\n", .{ site.line, format });
            } else {
                try report.print(allocator, "- L{d}: (built at runtime) `{s}`\n", .{ site.line, expression });
            }
        } else for (site.literals) |literal| {
            try report.print(allocator, "- L{d}: \"{s}\"\n", .{ site.line, literal });
        }
    }

    const report_path = "tooltip_report.md";
    cwd.writeFile(io, .{ .sub_path = report_path, .data = report.items }) catch
        @panic("failed to write tooltip_report.md");
    std.debug.print(
        "tooltip report: {d} literal sites across the ui sources ({d} built at runtime) -> {s}\n",
        .{ sites.items.len, runtime_site_count, report_path },
    );
}
