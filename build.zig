const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // === Generated IDs ===
    // Scans src/skills/ and src/effects/ to generate SkillId and EffectId enums.
    const generated = b.addWriteFiles();
    const generated_path = generated.add("generated.zig", generateIds(b));

    // === Generated lookups ===
    // Writes src/generated_lookups.zig with getEffectDefinition and getSkillDefinition.
    // Lives in src/ so it can use normal relative @import paths.
    generateLookupFile(b);

    // === Build info (game version) ===
    // Computes the game_version string at configure time (YYYY.MM.<commits
    // this month>[-dirty], derived from the build date + git) and exposes it
    // to code via @import("build_info").game_version. This is the runtime
    // "which build" stamp — advisory for replay validity — and is deliberately
    // NOT the build.zig.zon .version (which stays a static package-identity
    // number). See computeGameVersion.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "game_version", computeGameVersion(b));
    const build_info_module = build_info.createModule();

    // === Web target (deferred) ===
    // The web build will be a wasm32-emscripten exe that reuses the SAME
    // raylib backend + gameLoop as native (raylib supports web via emscripten).
    // The old wasm32-freestanding target (hand-written JS renderer driving an
    // exported `update`) was removed: we chose the raylib/emscripten path, so
    // that stub is dead. Add the emscripten exe here when the web phase lands.

    // === Native target (raylib desktop client) ===
    // The native build is the only compile that links raylib today. Its root is
    // src/native.zig (the raylib-driven entry point); the shared game logic in
    // src/main.zig stays raylib-free so the (future emscripten) web build and
    // the test build can compile it. See raylib_backend.zig / native.zig for
    // the platform seam.
    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const exe = b.addExecutable(.{
        .name = "ziglop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/native.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addAnonymousImport("generated", .{ .root_source_file = generated_path });
    exe.root_module.addImport("build_info", build_info_module);
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.linkLibrary(raylib_artifact);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // === Tests ===
    // Generate a test root that imports every src/*.zig so tests are discovered
    // automatically — no manual aggregator to keep in sync.
    generateTestRootFile(b);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generated_test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addAnonymousImport("generated", .{ .root_source_file = generated_path });
    tests.root_module.addImport("build_info", build_info_module);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// Computes the game_version string at configure time:
///   YYYY.MM.<commits this month>[-dirty]
/// The date comes from the build clock; the counter is `git rev-list --count`
/// scoped to the first of the current month (so it resets monthly and only
/// changes on commit, keeping the build cache stable). A dirty working tree
/// appends "-dirty".
///
/// Git is optional and we distinguish two "no number" cases:
///   * git ran and reported 0 commits this month -> a legitimate ".0".
///   * git couldn't tell us anything (no repo, git absent, e.g. a release
///     tarball) -> ".unofficial", flagging a build not stamped from tracked
///     history (and no dirty flag, since there's nothing to compare against).
/// This is a free-form string (not semver), so a zero-padded month / word in
/// the last field is fine.
fn computeGameVersion(b: *std.Build) []const u8 {
    const now_seconds: u64 = @intCast(std.Io.Clock.now(.real, b.graph.io).toSeconds());
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now_seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const year = year_day.year;
    const month = year_day.calculateMonthDay().month.numeric();

    const since = b.fmt("--since={d:0>4}-{d:0>2}-01", .{ year, month });
    if (gitOutput(b, &.{ "git", "rev-list", "--count", since, "HEAD" })) |raw_count| {
        const count = if (raw_count.len == 0) "0" else raw_count;
        const dirty = if (gitOutput(b, &.{ "git", "status", "--porcelain" })) |status|
            status.len != 0
        else
            false;
        return b.fmt("{d:0>4}.{d:0>2}.{s}{s}", .{ year, month, count, if (dirty) "-dirty" else "" });
    }

    // Git unavailable: mark the build as not stamped from tracked history.
    return b.fmt("{d:0>4}.{d:0>2}.unofficial", .{ year, month });
}

/// Run a git command, returning its trimmed stdout, or null if git is
/// unavailable or the command fails (non-zero exit). Never panics: the build
/// must work without a git checkout.
fn gitOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    var exit_code: u8 = 0;
    const stdout = b.runAllowFail(argv, &exit_code, .ignore) catch return null;
    if (exit_code != 0) return null;
    return std.mem.trim(u8, stdout, " \t\r\n");
}

/// Scans directories at build time and generates a Zig source file containing
/// SkillId and EffectId enums, with one variant per .zig file (excluding
/// interface files like skill.zig, effect.zig).
fn generateIds(b: *std.Build) []const u8 {
    var content: std.ArrayListUnmanaged(u8) = .empty;

    const skill_names = scanDir(b, "src/skills", &.{ "skill.zig", "helpers.zig" });
    appendStr(b, &content, "pub const SkillId = enum {\n");
    for (skill_names) |name| {
        appendStr(b, &content, b.fmt("    {s},\n", .{name}));
    }
    appendStr(b, &content, "};\n\n");

    const effect_names = scanDir(b, "src/effects", &.{"effect.zig"});
    appendStr(b, &content, "pub const EffectId = enum {\n");
    for (effect_names) |name| {
        appendStr(b, &content, b.fmt("    {s},\n", .{name}));
    }
    appendStr(b, &content, "};\n");

    return content.items;
}

/// Small helper: append a slice to a build-time byte buffer, panicking on OOM.
fn appendStr(b: *std.Build, list: *std.ArrayListUnmanaged(u8), text: []const u8) void {
    list.appendSlice(b.allocator, text) catch @panic("alloc failed");
}

/// Generates src/generated_lookups.zig with getEffectDefinition and getSkillDefinition.
/// This file lives in src/ so it can use normal relative @import paths to reach
/// skill and effect files. It is regenerated on every build.
fn generateLookupFile(b: *std.Build) void {
    const io = b.graph.io;
    var content: std.ArrayListUnmanaged(u8) = .empty;

    appendStr(b, &content,
        \\// AUTO-GENERATED by build.zig — do not edit manually.
        \\// Provides lookup functions mapping EffectId/SkillId to their definitions.
        \\
        \\const effect_mod = @import("effects/effect.zig");
        \\const skill_mod = @import("skills/skill.zig");
        \\const Effect = effect_mod.Effect;
        \\const Skill = skill_mod.Skill;
        \\const generated = @import("generated");
        \\const EffectId = generated.EffectId;
        \\const SkillId = generated.SkillId;
        \\
        \\
    );

    // Effect lookup
    const effect_names = scanDir(b, "src/effects", &.{"effect.zig"});
    appendStr(b, &content, "pub fn getEffectDefinition(effect_id: EffectId) Effect {\n");
    appendStr(b, &content, "    return switch (effect_id) {\n");
    for (effect_names) |name| {
        appendStr(b, &content, b.fmt("        .{s} => @import(\"effects/{s}.zig\").effect,\n", .{ name, name }));
    }
    appendStr(b, &content, "    };\n}\n\n");

    // Skill lookup
    const skill_names = scanDir(b, "src/skills", &.{ "skill.zig", "helpers.zig" });
    appendStr(b, &content, "pub fn getSkillDefinition(skill_id: SkillId) ?Skill {\n");
    appendStr(b, &content, "    return switch (skill_id) {\n");
    for (skill_names) |name| {
        appendStr(b, &content, b.fmt(
            "        .{s} => if (@hasDecl(@import(\"skills/{s}.zig\"), \"skill\")) @import(\"skills/{s}.zig\").skill else null,\n",
            .{ name, name, name },
        ));
    }
    appendStr(b, &content, "    };\n}\n");

    // Write to src/generated_lookups.zig
    var dir = std.Io.Dir.cwd().openDir(io, "src", .{}) catch
        @panic("failed to open src/ directory");
    defer dir.close(io);

    dir.writeFile(io, .{
        .sub_path = "generated_lookups.zig",
        .data = content.items,
    }) catch @panic("failed to write src/generated_lookups.zig");
}

/// Generates src/generated_test_root.zig, a test root that imports every
/// .zig file under src/ (recursively) so their `test` blocks are discovered
/// automatically. Lives in src/ so it can use relative @import paths. New test
/// files are picked up on the next build with no manual wiring.
fn generateTestRootFile(b: *std.Build) void {
    const io = b.graph.io;

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    collectZigFiles(b, "", &paths);

    // Deterministic output.
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_inner: []const u8) bool {
            return std.mem.order(u8, a, b_inner) == .lt;
        }
    }.lessThan);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(b, &content,
        "// AUTO-GENERATED by build.zig — do not edit manually.\n" ++
        "// Imports every src/*.zig so their tests are discovered automatically.\n" ++
        "test {\n",
    );
    for (paths.items) |path| {
        appendStr(b, &content, b.fmt("    _ = @import(\"{s}\");\n", .{path}));
    }
    appendStr(b, &content, "}\n");

    var dir = std.Io.Dir.cwd().openDir(io, "src", .{}) catch
        @panic("failed to open src/ directory");
    defer dir.close(io);
    dir.writeFile(io, .{
        .sub_path = "generated_test_root.zig",
        .data = content.items,
    }) catch @panic("failed to write src/generated_test_root.zig");
}

/// Recursively collect .zig file paths under src/, relative to src/ (using
/// forward slashes for @import). `rel_prefix` is the path accumulated so far.
fn collectZigFiles(
    b: *std.Build,
    rel_prefix: []const u8,
    list: *std.ArrayListUnmanaged([]const u8),
) void {
    const io = b.graph.io;
    const dir_path = if (rel_prefix.len == 0) "src" else b.fmt("src/{s}", .{rel_prefix});

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        @panic("failed to open directory for test root generation");
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch @panic("failed to iterate directory")) |entry| {
        const rel = if (rel_prefix.len == 0)
            b.dupe(entry.name)
        else
            b.fmt("{s}/{s}", .{ rel_prefix, entry.name });

        switch (entry.kind) {
            .directory => collectZigFiles(b, rel, list),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                // Skip the generated root itself to avoid a self-import.
                if (std.mem.eql(u8, rel, "generated_test_root.zig")) continue;
                // Skip the raylib-linked platform files: the test build is a
                // headless logic compile and must not pull in raylib (see the
                // native exe wiring above and the platform seam).
                if (std.mem.eql(u8, rel, "native.zig")) continue;
                if (std.mem.eql(u8, rel, "raylib_backend.zig")) continue;
                list.append(b.allocator, rel) catch @panic("append failed");
            },
            else => {},
        }
    }
}

/// Scans a directory for .zig files, excludes the given interface files,
/// and returns sorted file stems (e.g. "slice" from "slice.zig").
fn scanDir(b: *std.Build, dir_path: []const u8, exclude: []const []const u8) []const []const u8 {
    const io = b.graph.io;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        @panic("failed to open directory for ID generation");
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch @panic("failed to iterate directory")) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".zig")) continue;

        // Check exclusion list
        var excluded = false;
        for (exclude) |ex| {
            if (std.mem.eql(u8, name, ex)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;

        // Strip .zig extension
        const stem = name[0 .. name.len - 4];
        names.append(b.allocator, b.allocator.dupe(u8, stem) catch @panic("alloc failed")) catch @panic("append failed");
    }

    // Sort for deterministic output
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_inner: []const u8) bool {
            return std.mem.order(u8, a, b_inner) == .lt;
        }
    }.lessThan);

    return names.items;
}
