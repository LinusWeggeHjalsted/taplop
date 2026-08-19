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

    // === Generated assets ===
    // Emits generated_assets.zig at the PROJECT ROOT embedding every file
    // under data/ and assets/ as @embedFile bytes, keyed by project-root-
    // relative path. Exposed as the named module "generated_assets" so its
    // package root is the project root (letting @embedFile reach data/ and
    // assets/, which sit outside src/). This is the single-file-exe content
    // source — see AGENTS.md "File System & IO". Re-runs every build so
    // new/edited content is picked up (content edits to existing files
    // require a recompile, which `zig build run` does anyway).
    const assets_module = generateAssetsFile(b);

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
        // Take over frame control ourselves: EndDrawing() then only flushes the
        // render batch (no SwapScreenBuffer, no PollInputEvents, no frame-rate
        // WaitTime). We call swapScreenBuffer() in render() and pollInputEvents()
        // in pollInput() so the uncapped logic loop owns event polling — without
        // this, EndDrawing()'s built-in PollInputEvents eats input events that
        // accumulate during the vsync block (lost clicks).
        .config = "-DSUPPORT_CUSTOM_FRAME_CONTROL",
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
    exe.root_module.addImport("generated_assets", assets_module);
    exe.root_module.linkLibrary(raylib_artifact);

    // Strip system .so files from the raylib archive before the exe links.
    //
    // raylib_zig's linkLinux() calls linkSystemLibrary("GL"/"X11"/...) on the
    // raylib module, which archives the .so files into libraylib.a. LLD
    // warns about .so files inside a .a archive ("neither ET_REL nor LLVM
    // bitcode"), and Zig's build runner treats LLD's stderr as a build
    // failure. The exe already links the system libs directly (-lGL -lX11
    // etc. propagated from the raylib module), so the .so copies in the
    // archive are redundant — safe to remove.
    //
    // We use zig's own ar (LLVM ar, which handles the full-path member names;
    // GNU ar silently fails on them) via a shell one-liner that dynamically
    // finds and strips any .so member (paths are system-dependent: /lib64 on
    // Arch, /usr/lib/x86_64-linux-gnu on Debian, etc.). The step depends on
    // the raylib artifact (so the archive exists) and the exe depends on the
    // step (so it runs before linking).
    const strip_so = b.addSystemCommand(&.{
        "sh", "-c",
        "ar t \"$1\" | grep '\\.so$' | while read f; do \"$0\" ar d \"$1\" \"$f\"; done",
    });
    strip_so.addArg(b.graph.zig_exe); // $0 — zig executable (for `zig ar d`)
    strip_so.addFileArg(raylib_artifact.getEmittedBin()); // $1 — libraylib.a path
    strip_so.step.dependOn(&raylib_artifact.step);
    exe.step.dependOn(&strip_so.step);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // === Web target (emscripten + raylib) ===
    // The web build reuses the SAME raylib backend + gameLoop as native (route
    // B). Built as a wasm32-emscripten library, then packaged into HTML via
    // emcc (zemscripten). Opt-in: `zig build web` produces zig-out/web/ziglop.html.
    // See AGENTS.md "Platform Seam (raylib)" + "File System & IO".
    //
    // Phase 0 (toolchain spike): src/web.zig is a minimal raylib window to
    // validate emcc + raylib + wasm compile and render. The real game loop
    // wiring lands in Phase 1 (frame-body refactor) + Phase 2 (IDBFS + game).
    const zemscripten = @import("zemscripten");

    const web_target = b.resolveTargetQuery(.{ .os_tag = .emscripten, .cpu_arch = .wasm32 });
    const raylib_web_dep = b.dependency("raylib_zig", .{
        .target = web_target,
        .optimize = optimize,
        // Same custom frame control as native: EndDrawing() only flushes the
        // render batch; we drive swapScreenBuffer + pollInputEvents ourselves
        // from the emscripten main-loop callback (no asyncify).
        .config = "-DSUPPORT_CUSTOM_FRAME_CONTROL",
    });
    const raylib_web = raylib_web_dep.module("raylib");
    const raylib_web_artifact = raylib_web_dep.artifact("raylib");

    const wasm = b.addLibrary(.{
        .name = "ziglop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web.zig"),
            .target = web_target,
            .optimize = optimize,
        }),
    });
    wasm.root_module.addAnonymousImport("generated", .{ .root_source_file = generated_path });
    wasm.root_module.addImport("build_info", build_info_module);
    wasm.root_module.addImport("raylib", raylib_web);
    wasm.root_module.addImport("generated_assets", assets_module);
    wasm.root_module.linkLibrary(raylib_web_artifact);

    var emcc_flags = zemscripten.emccDefaultFlags(b.allocator, .{
        .optimize = optimize,
        .fsanitize = true,
    });
    var emcc_settings = zemscripten.emccDefaultSettings(b.allocator, .{
        .optimize = optimize,
        .emsdk_allocator = .emmalloc,
    });
    // The game uses the emscripten filesystem (IDBFS for persistence in Phase 2;
    // embedded assets don't need it but FileSource.readFile falls back to the
    // persistent dir, so the FS must exist). Allow memory growth so the wasm
    // heap can expand beyond the initial allocation. USE_GLFW=3 links
    // emscripten's GLFW3 shim — raylib's PLATFORM_WEB calls glfw* functions
    // that emscripten provides via this shim (matching the raylib C library's
    // own emccDefaultSettings wrapper).
    // The game uses the emscripten filesystem: IDBFS for persistence (mounted
    // at /ziglop in web.zig), and embedded assets fall back through
    // FileSource.readFile to the persistent dir. FORCE_FILESYSTEM enables the
    // FS API; -lidbfs.js includes the IDBFS backend (no longer default in
    // recent emscripten). ALLOW_MEMORY_GROWTH lets the wasm heap expand.
    // USE_GLFW=3 links emscripten's GLFW3 shim (raylib's PLATFORM_WEB uses it).
    emcc_settings.put("FORCE_FILESYSTEM", "1") catch @panic("emcc settings OOM");
    emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch @panic("emcc settings OOM");
    emcc_settings.put("USE_GLFW", "3") catch @panic("emcc settings OOM");
    // The game's main() does substantial work at startup (config loads, game-
    // state construction, deep copies) on top of raylib's init; the emscripten
    // default 64KB stack overflows. 8MB is generous and matches typical native
    // thread stacks; ALLOW_MEMORY_GROWTH keeps the heap flexible regardless.
    emcc_settings.put("STACK_SIZE", "8mb") catch @panic("emcc settings OOM");

    // -lidbfs.js: include the IDBFS backend (needed by web.zig's mount).
    // Not a -s setting; passed as a linker flag via emcc_flags.
    emcc_flags.put("-lidbfs.js", {}) catch @panic("emcc flags OOM");

    // Custom HTML shell (no emscripten/raylib branding). The canvas id
    // matches the one Module.canvas points at in the shell's <script>.
    const shell_path = b.path("web/shell.html");

    const web_install_dir: std.Build.InstallDir = .{ .custom = "web" };
    const emcc_step = zemscripten.emccStep(b, wasm, .{
        .optimize = optimize,
        .flags = emcc_flags,
        .settings = emcc_settings,
        .shell_file_path = shell_path,
        .install_dir = web_install_dir,
    });
    emcc_step.dependOn(zemscripten.activateEmsdkStep(b));

    const web_step = b.step("web", "Build the web (emscripten) client");
    web_step.dependOn(emcc_step);

    // `zig build emrun` — serve the web build locally and open it in a browser.
    const emrun_step = zemscripten.emrunStep(
        b,
        b.getInstallPath(web_install_dir, "ziglop.html"),
        &.{},
    );
    emrun_step.dependOn(emcc_step);
    const emrun_build_step = b.step("emrun", "Build and serve the web app locally using emrun");
    emrun_build_step.dependOn(emrun_step);

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
    tests.root_module.addImport("generated_assets", assets_module);
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
                if (std.mem.eql(u8, rel, "web.zig")) continue;
                list.append(b.allocator, rel) catch @panic("append failed");
            },
            else => {},
        }
    }
}

/// Generates generated_assets.zig at the PROJECT ROOT, embedding every file
/// under data/ and assets/ as @embedFile bytes into a std.StaticStringMap
/// keyed by project-root-relative path (e.g. "data/settings.txt",
/// "assets/world/tile.png"). This bakes all shipped content into the exe so it
/// runs from anywhere. @embedFile needs comptime-known path literals, so the
/// entries must be enumerated in a generated source file rather than
/// discovered at runtime.
///
/// The file is emitted at the project root (not src/) and returned as a named
/// module so its package root covers data/ and assets/ (which sit outside
/// src/); @embedFile paths are then plain project-root-relative (no "../").
/// initComptime sorts internally, but we pre-sort for deterministic output.
fn generateAssetsFile(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;

    var entries: std.ArrayListUnmanaged([2][]const u8) = .empty;
    defer entries.deinit(b.allocator);

    collectContentFiles(b, "data", "data", &entries);
    collectContentFiles(b, "assets", "assets", &entries);

    // Sort by key for deterministic output.
    std.mem.sort([2][]const u8, entries.items, {}, struct {
        fn lessThan(_: void, a: [2][]const u8, b_inner: [2][]const u8) bool {
            return std.mem.order(u8, a[0], b_inner[0]) == .lt;
        }
    }.lessThan);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(b, &content,
        "// AUTO-GENERATED by build.zig — do not edit manually.\n" ++
        "// Embeds every file under data/ and assets/ as @embedFile bytes,\n" ++
        "// keyed by project-root-relative path. See AGENTS.md \"File System & IO\".\n" ++
        "const std = @import(\"std\");\n\n" ++
        "pub const map = std.StaticStringMap([]const u8).initComptime(.{\n");
    for (entries.items) |entry| {
        const key = entry[0];
        const embed_path = entry[1];
        appendStr(b, &content, b.fmt("    .{{ \"{s}\", @embedFile(\"{s}\") }},\n", .{ key, embed_path }));
    }
    appendStr(b, &content, "});\n");

    // Write at the project root (package root for the module) so @embedFile
    // can reach data/ and assets/.
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "generated_assets.zig",
        .data = content.items,
    }) catch @panic("failed to write generated_assets.zig");

    return b.addModule("generated_assets", .{ .root_source_file = b.path("generated_assets.zig") });
}

/// Recursively collect all files under `dir_path`, recording (key, embed_path)
/// pairs into `entries`. `key_prefix` is the project-root-relative prefix the
/// keys carry (e.g. "data" or "assets"). `embed_path` is the same as the key
/// (both project-root-relative, since the generated file lives at the root).
fn collectContentFiles(
    b: *std.Build,
    dir_path: []const u8,
    key_prefix: []const u8,
    entries: *std.ArrayListUnmanaged([2][]const u8),
) void {
    const io = b.graph.io;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        @panic("failed to open directory for asset embedding");
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch @panic("failed to iterate directory")) |entry| {
        const key = b.fmt("{s}/{s}", .{ key_prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                const sub_dir_path = b.fmt("{s}/{s}", .{ dir_path, entry.name });
                collectContentFiles(b, sub_dir_path, key, entries);
            },
            .file => {
                // embed_path == key (project-root-relative from the root file).
                entries.append(b.allocator, .{ key, key }) catch @panic("append failed");
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
