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
    // under data/ and assets/ (plus the root LICENSE-*.txt files) as
    // @embedFile bytes, keyed by project-root-relative path. Exposed as the
    // named module "generated_assets" so its package root is the project
    // root (letting @embedFile reach data/ and assets/, which sit outside
    // src/). This is the single-file-exe content source — see DESIGN → File
    // System & IO. Re-runs every build so new/edited content is picked up
    // (content edits to existing files require a recompile, which `zig build
    // run` does anyway).
    const assets_module = generateAssetsFile(b);

    // === Generated sprite metadata ===
    // Emits generated_sprite_metadata.zig at the PROJECT ROOT with pixel
    // dimensions (from each PNG's IHDR) for every assets/**/*.png, keyed by
    // sprite id. The parser uses this to populate `Decoration.pixel_dims` for
    // shipped sprites with zero I/O (custom sprites resolve dims at runtime).
    // See DESIGN → Decorations & Footprint.
    const sprite_metadata_module = generateSpriteMetadataFile(b);

    // `.config` flags are injected into the raylib C library compile. The
    // FONT_SDF_* defines widen the SDF glyph encoding for the build-time SDF
    // font-atlas generator (tools/sdf_atlas_generator.zig — the atlas is
    // embedded and NO SDF code runs at game runtime, so these defines only
    // matter to the generator's raylib dependency below). The values MUST
    // match the `sdf_pixel_dist_scale` / `sdf_char_padding` constants in
    // src/raylib (the shader decodes the field assuming this
    // encoding, and the runtime validates the blob's baked params against
    // them).
    const raylib_sdf_config_flags = "-DSUPPORT_CUSTOM_FRAME_CONTROL " ++
        "-DFONT_SDF_CHAR_PADDING=22 " ++
        "-DFONT_SDF_PIXEL_DIST_SCALE=6.0f";

    // === Generated SDF font atlas ===
    // A build-time HOST tool (tools/sdf_atlas_generator.zig) links raylib as
    // a library (no window — glyph SDF generation is pure CPU) and bakes the
    // SDF glyph atlas + per-glyph metrics into a binary blob via the SAME
    // raylib code path (loadFontData(.sdf) + genImageFontAtlas) the runtime
    // used previously — zero metric drift by construction. The blob is
    // embedded through the `generated_sdf_font` module (same shape as
    // `generated_sprite_metadata`); the backend in src/raylib parses it and
    // assembles the rl.Font at init, so NO SDF computation runs at game
    // startup (it measured ~1.4s in a release build). Regenerates only when
    // the font file or generator changes (build cache).
    const sdf_generator_exe = b.addExecutable(.{
        .name = "sdf_atlas_generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sdf_atlas_generator.zig"),
            .target = b.resolveTargetQuery(.{}), // always the build host
            .optimize = .Debug, // fast to compile; the SDF run is a few seconds slower but only runs once per clean build
        }),
    });
    const raylib_generator_dep = b.dependency("raylib_zig", .{
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        // The FONT_SDF_* defines ARE load-bearing here (they set the SDF
        // encoding range raylib bakes into the glyphs); see the comment on
        // raylib_sdf_config_flags above.
        .config = raylib_sdf_config_flags,
    });
    sdf_generator_exe.root_module.addImport("raylib", raylib_generator_dep.module("raylib"));
    sdf_generator_exe.root_module.linkLibrary(raylib_generator_dep.artifact("raylib"));
    const sdf_generator_run = b.addRunArtifact(sdf_generator_exe);
    // Input file (dependency-tracked: editing the font regenerates the atlas)
    // then output blob path.
    sdf_generator_run.addFileArg(b.path("assets/fonts/cause-semibold.ttf"));
    const sdf_blob = sdf_generator_run.addOutputFileArg("sdf_font.bin");

    // Wrapper module: package root = write-files dir, so @embedFile reaches
    // the copied blob without escaping the package root.
    const sdf_write_files = b.addWriteFiles();
    _ = sdf_write_files.addCopyFile(sdf_blob, "sdf_font.bin");
    const sdf_font_module = b.createModule(.{
        .root_source_file = sdf_write_files.add(
            "sdf_font.zig",
            "pub const bytes = @embedFile(\"sdf_font.bin\");\n",
        ),
    });

    // === Build info (game version) ===
    // Computes the game_version string at configure time (YYYY.MM.<commits
    // this month>[-dirty], derived from the build date + git) and exposes it
    // to code via @import("build_info").game_version. This is the runtime
    // "which build" stamp — advisory for replay validity — and is deliberately
    // NOT the build.zig.zon .version (which stays a static package-identity
    // number). See computeGameVersion.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "game_version", computeGameVersion(b));
    // Dev mode gates dev-only keybinds (e.g. skip_level on ctrl+Enter). A
    // `-Ddev-mode` build option, defaulted to `optimize == .Debug` so
    // `zig build run` (debug) gets dev tools for free while release/web
    // builds stay clean. The gate is read at the handler site via
    // `@import("build_info").dev_mode` (comptime-constant per build).
    const dev_mode = b.option(bool, "dev-mode", "Enable dev-only tools (skip level, etc.)") orelse
        (optimize == .Debug);
    build_info.addOption(bool, "dev_mode", dev_mode);
    // Opt-in emscripten runtime debug features (ASSERTIONS, SAFE_HEAP, source
    // maps) for browser-devtools work. Off by default for faster web links.
    const web_debug_runtime = b.option(bool, "web-debug-runtime", "Enable emscripten ASSERTIONS/SAFE_HEAP/source maps") orelse false;
    // Render target resolution is a RUNTIME setting (`render_resolution` in
    // settings.txt, the settings-screen 4-choice) — the backend recreates
    // its RenderTexture live. See DESIGN → Platform Seam → Render target
    // resolution.
    const build_info_module = build_info.createModule();

    // === Native target (raylib desktop client) ===
    // The native + web builds both link raylib (web via the emscripten target
    // below). The native root is src/native.zig (the raylib-driven entry
    // point); the shared game logic in src/main.zig stays raylib-free so the
    // web build and the headless test build can compile it. See
    // src/raylib/backend.zig / native.zig for the platform seam.
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
    exe.root_module.addImport("generated_sprite_metadata", sprite_metadata_module);
    exe.root_module.addImport("generated_sdf_font", sdf_font_module);
    exe.root_module.linkLibrary(raylib_artifact);

    // macOS: the exe's LINK step needs the framework search paths (the
    // .tbd stubs) on its own module — raylib's linkMacOS adds them to the
    // raylib library's module and the -F paths don't propagate to a
    // consumer's link line (only the -framework flags do). Same package
    // raylib declares (deduped by hash); lazy, so a Linux/Windows build
    // never fetches it.
    if (target.result.os.tag == .macos) {
        if (b.lazyDependency("xcode_frameworks", .{})) |frameworks| {
            exe.root_module.addSystemFrameworkPath(frameworks.path("Frameworks"));
            exe.root_module.addLibraryPath(frameworks.path("lib"));
            // Link OpenGL explicitly: the dev diag section calls
            // glGetString directly (raylib resolves GL through its glad
            // loader, so nothing else links OpenGL). The unresolved mac
            // 9-slice panel bug needs it too if a fix lands that touches GL
            // — see TODO → macOS native port + DONE.md, "mac 9-slice
            // panels" entries.
            exe.root_module.linkFramework("OpenGL", .{});
        } else {
            // First run after the dep is needed: zig fetches it now and the
            // build re-runs; a second `zig build` succeeds.
            return;
        }
    }

    // Strip system .so files from the raylib archive before the exe links.
    // Linux-only: the .so members come from raylib_zig's linkLinux(); the
    // shell one-liner no-ops on other targets, but skipping it entirely keeps
    // the macos build from shelling out at all.
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
    if (target.result.os.tag == .linux) {
        const strip_so = b.addSystemCommand(&.{
            "sh", "-c",
            "ar t \"$1\" | grep '\\.so$' | while read f; do \"$0\" ar d \"$1\" \"$f\"; done",
        });
        strip_so.addArg(b.graph.zig_exe); // $0 — zig executable (for `zig ar d`)
        strip_so.addFileArg(raylib_artifact.getEmittedBin()); // $1 — libraylib.a path
        strip_so.step.dependOn(&raylib_artifact.step);
        exe.step.dependOn(&strip_so.step);
    }

    b.installArtifact(exe);

    // macOS app bundle: `zig build -Dtarget=aarch64-macos` installs, next to
    // the bare zig-out/bin/ziglop, a double-clickable zig-out/ziglop.app/
    // with the exe at Contents/MacOS/ziglop and a minimal Info.plist. No icon
    // yet (no suitable art; macOS falls back to the generic app icon) and no
    // codesigning — that needs a mac host; an unsigned bundle runs locally,
    // a browser-downloaded copy needs `xattr -cr ziglop.app` once.
    if (target.result.os.tag == .macos) {
        const app_contents = b.addWriteFiles();
        _ = app_contents.add("Info.plist", appBundleInfoPlist());
        const install_plist = b.addInstallDirectory(.{
            .source_dir = app_contents.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "ziglop.app/Contents",
        });
        const install_bundle_exe = b.addInstallFileWithDir(
            exe.getEmittedBin(),
            .{ .custom = "ziglop.app/Contents/MacOS" },
            "ziglop",
        );
        install_plist.step.dependOn(&install_bundle_exe.step);
        b.getInstallStep().dependOn(&install_plist.step);
    }

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
    // See DESIGN → Platform Seam (raylib) + File System & IO.
    const zemscripten = @import("zemscripten");

    const web_target = b.resolveTargetQuery(.{ .os_tag = .emscripten, .cpu_arch = .wasm32 });
    const raylib_web_dep = b.dependency("raylib_zig", .{
        .target = web_target,
        .optimize = optimize,
        // WebGL 2 (GL ES 3.0), NOT the auto-default WebGL 1: WebGL1 forbids
        // mipmaps on non-power-of-two textures (most of our art is NPOT —
        // 512x640 entities, arbitrary custom-mission assets) and has no
        // `fwidth` for shader antialiasing. Our custom shaders are GLSL 330
        // on desktop / 300 es on web. Browser floor: Safari/iOS 15 (2021);
        // all evergreen desktop browsers since 2017. See DESIGN → Platform
        // Seam (WebGL 2).
        .opengl_version = .gles_3,
        // Same custom frame control as native: EndDrawing() only flushes the
        // render batch; we drive swapScreenBuffer + pollInputEvents ourselves
        // from the emscripten main-loop callback (no asyncify).
        .config = "-DSUPPORT_CUSTOM_FRAME_CONTROL " ++
        // Web audio onset latency (the measured diagnosis — see DESIGN →
        // Platform Seam → Web audio onset latency): raylib's default device
        // period (0) is overridden by miniaudio's webaudio backend to 33ms ->
        // a 2048-frame (~43ms @ 48kHz) ScriptProcessorNode buffer, doubling
        // the node's inherent ~1-2-buffer fill-ahead lead on every sound's
        // onset. 1024 frames (~21ms) halves that inherent lead and was
        // measured serviceable at 60fps (AudioContext clock ratio 1.000 —
        // the main thread services a fill every ~21ms against ~16.7ms frame
        // gaps; 512/~10.7ms would chronically starve). The DOMINANT web
        // onset delay — the queue BANKED by long main-thread blocks — is
        // handled by web.zig's queue watchdog, not by this knob. Native
        // keeps raylib's default (a real audio thread, 10ms period, instant
        // by the same measurement).
        "-DAUDIO_DEVICE_PERIOD_SIZE_IN_FRAMES=1024",
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
    wasm.root_module.addImport("generated_sprite_metadata", sprite_metadata_module);
    wasm.root_module.addImport("generated_sdf_font", sdf_font_module);
    wasm.root_module.linkLibrary(raylib_web_artifact);

    var emcc_flags = zemscripten.emccDefaultFlags(b.allocator, .{
        .optimize = optimize,
        .fsanitize = true,
    });
    var emcc_settings = zemscripten.emccDefaultSettings(b.allocator, .{
        .optimize = optimize,
        .emsdk_allocator = .emmalloc,
    });
    // Strip the expensive emscripten runtime-debug features from Debug web
    // builds to speed up the emcc link (the dominant web-build cost, ~17s
    // of the ~18s incremental). ASSERTIONS + SAFE_HEAP instrument every
    // memory access / API call; -gsource-map parses DWARF to build source
    // maps. The Zig compiler debug checks + allocator debug mode catch the
    // same classes of bug; these emscripten features are opt-in via
    // -Dweb-debug-runtime for browser-devtools work. -fsanitize=undefined
    // stays (raylib C objects reference UBSan symbols).
    if (optimize == .Debug and !web_debug_runtime) {
        _ = emcc_flags.remove("-gsource-map");
        emcc_settings.put("ASSERTIONS", "0") catch @panic("emcc settings OOM");
        emcc_settings.put("SAFE_HEAP", "0") catch @panic("emcc settings OOM");
        emcc_settings.put("USE_OFFSET_CONVERTER", "0") catch @panic("emcc settings OOM");
    }
    // The game uses the emscripten filesystem: an in-memory (MEMFS) mount at
    // /ziglop for the persistent dir (web.zig — the session-scoped storage
    // model; NO IDBFS, browser storage is never touched — see DESIGN → File
    // System & IO → Web storage model), and embedded assets fall back through
    // FileSource.readFile to the persistent dir. FORCE_FILESYSTEM enables the
    // FS API (the JS download/upload seams use it).
    // ALLOW_MEMORY_GROWTH lets the wasm heap expand.
    // USE_GLFW=3 links emscripten's GLFW3 shim (raylib's PLATFORM_WEB uses it).
    emcc_settings.put("FORCE_FILESYSTEM", "1") catch @panic("emcc settings OOM");
    emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch @panic("emcc settings OOM");
    emcc_settings.put("USE_GLFW", "3") catch @panic("emcc settings OOM");
    // WebGL 2 context settings — MUST stay in lockstep with the web raylib
    // dependency's `opengl_version = .gles_3` above: with it, raylib compiles
    // for GL ES 3 and submits its built-in shaders as `#version 300 es`, but
    // emcc's GL glue defaults to a WebGL 1 context (MIN/MAX_WEBGL_VERSION=1)
    // — the mismatch makes every shader fail with "unsupported shader
    // version 300" and the page renders black. Raylib pairs the two the same
    // way (its examples Makefile's BUILD_WEB_WEBGL2 adds these settings).
    emcc_settings.put("MIN_WEBGL_VERSION", "2") catch @panic("emcc settings OOM");
    emcc_settings.put("MAX_WEBGL_VERSION", "2") catch @panic("emcc settings OOM");
    // The game's main() does substantial work at startup (config loads, game-
    // state construction, deep copies) on top of raylib's init; the emscripten
    // default 64KB stack overflows. 8MB is generous and matches typical native
    // thread stacks; ALLOW_MEMORY_GROWTH keeps the heap flexible regardless.
    emcc_settings.put("STACK_SIZE", "8mb") catch @panic("emcc settings OOM");

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
    tests.root_module.addImport("generated_sprite_metadata", sprite_metadata_module);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // === Sound asset overview (scripts/sound_report.sh) ===
    // A host tool that walks the engine's enums and writes sound_report.md —
    // the sound designer's complete inventory of wired paths (status per
    // asset: shipped / shadowed / MISSING-silent). Root lives in src/ so it
    // can import types.zig; the same `generated` + `build_info` modules the
    // game uses keep it enum-keyed (no hand-maintained list).
    const sound_report_exe = b.addExecutable(.{
        .name = "sound_report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sound_report.zig"),
            .target = b.resolveTargetQuery(.{}), // always the build host
            .optimize = .Debug,
            // libc for std.c.getenv (the native.zig resolvePersistentPath
            // discipline — the tool mirrors it without raylib).
            .link_libc = true,
        }),
    });
    sound_report_exe.root_module.addAnonymousImport("generated", .{ .root_source_file = generated_path });
    sound_report_exe.root_module.addImport("build_info", build_info_module);
    // file_source.zig (the shared audio-extension policy) imports it.
    sound_report_exe.root_module.addImport("generated_assets", assets_module);
    const sound_report_run = b.addRunArtifact(sound_report_exe);
    // Runs from the project root so it can stat assets/ + write
    // sound_report.md where the developer expects it.
    sound_report_run.setCwd(b.path("."));
    const sound_report_step = b.step("sound-report", "Generate sound_report.md (the wired-sound asset inventory)");
    sound_report_step.dependOn(&sound_report_run.step);

    // === Art asset overview (scripts/art_report.sh) ===
    // A host tool that enumerates every consumable sprite id (engine enums +
    // derivations, src string literals, shipped data sprite references) and
    // writes art_report.md — the artist's self-updating inventory + shopping
    // list (status per id: shipped / shadowed / MISSING-draws-magenta, plus
    // shipped-but-unconsumed orphans). Root lives in src/ so it can import
    // types.zig + the ui facade; the `generated` + `build_info` modules cover
    // types.zig's imports.
    const art_report_exe = b.addExecutable(.{
        .name = "art_report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/art_report.zig"),
            .target = b.resolveTargetQuery(.{}), // always the build host
            .optimize = .Debug,
            // libc for std.c.getenv (the resolvePersistentPath discipline).
            .link_libc = true,
        }),
    });
    art_report_exe.root_module.addAnonymousImport("generated", .{ .root_source_file = generated_path });
    art_report_exe.root_module.addImport("build_info", build_info_module);
    const art_report_run = b.addRunArtifact(art_report_exe);
    art_report_run.setCwd(b.path("."));
    const art_report_step = b.step("art-report", "Generate art_report.md (the consumed-sprite asset inventory)");
    art_report_step.dependOn(&art_report_run.step);

    // === Gradient contrast report (scripts/gradient_report.sh) ===
    // A host tool that reads data/color_themes.txt through the game's own
    // parser + loader and writes gradient_report.md — the artist's
    // perceptual-spacing reference: ΔE76 per ramp step, WCAG contrast on
    // the renderer's structural seams, flags + suggested repairs for
    // "too close" colors. Same module needs as the game's loader chain.
    const gradient_report_exe = b.addExecutable(.{
        .name = "gradient_report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gradient_report.zig"),
            .target = b.resolveTargetQuery(.{}), // always the build host
            .optimize = .Debug,
        }),
    });
    gradient_report_exe.root_module.addAnonymousImport("generated", .{ .root_source_file = generated_path });
    gradient_report_exe.root_module.addImport("build_info", build_info_module);
    gradient_report_exe.root_module.addImport("generated_assets", assets_module);
    gradient_report_exe.root_module.addImport("generated_sprite_metadata", sprite_metadata_module);
    const gradient_report_run = b.addRunArtifact(gradient_report_exe);
    gradient_report_run.setCwd(b.path("."));
    const gradient_report_step = b.step("gradient-report", "Generate gradient_report.md (the gradient spacing + seam contrast report)");
    gradient_report_step.dependOn(&gradient_report_run.step);
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

/// The .app bundle's Info.plist. Minimal but complete enough for Finder +
/// Gatekeeper: identity fields, an LSMinimumSystemVersion matching what Zig
/// builds against (aarch64 needs macOS 11), and NSHighResolutionCapable so
/// retina rendering isn't forced to 1x. No icon yet (no suitable art).
fn appBundleInfoPlist() []const u8 {
    return \\<?xml version="1.0" encoding="UTF-8"?>
\\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
\\<plist version="1.0">
\\<dict>
\\    <key>CFBundleDevelopmentRegion</key>
\\    <string>en</string>
\\    <key>CFBundleExecutable</key>
\\    <string>ziglop</string>
\\    <key>CFBundleIdentifier</key>
\\    <string>com.linusweggehjalsted.ziglop</string>
\\    <key>CFBundleInfoDictionaryVersion</key>
\\    <string>6.0</string>
\\    <key>CFBundleName</key>
\\    <string>Ziglop</string>
\\    <key>CFBundlePackageType</key>
\\    <string>APPL</string>
\\    <key>CFBundleShortVersionString</key>
\\    <string>0.0.0</string>
\\    <key>CFBundleVersion</key>
\\    <string>0.0.0</string>
\\    <key>LSMinimumSystemVersion</key>
\\    <string>11.0</string>
\\    <key>NSHighResolutionCapable</key>
\\    <true/>
\\    <key>NSPrincipalClass</key>
\\    <string>NSApplication</string>
\\</dict>
\\</plist>
    ;
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
/// SkillId and EffectId enums, with one variant per .zig file. Every file in
/// src/skills/ and src/effects/ is a skill/effect definition; the interface
/// and support files live at src/ root.
fn generateIds(b: *std.Build) []const u8 {
    var content: std.ArrayListUnmanaged(u8) = .empty;

    const skill_names = scanDir(b, "src/skills");
    appendStr(b, &content, "pub const SkillId = enum {\n");
    for (skill_names) |name| {
        appendStr(b, &content, b.fmt("    {s},\n", .{name}));
    }
    appendStr(b, &content, "};\n\n");

    const effect_names = scanDir(b, "src/effects");
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
        \\const effect_mod = @import("effect.zig");
        \\const skill_mod = @import("skill.zig");
        \\const Effect = effect_mod.Effect;
        \\const Skill = skill_mod.Skill;
        \\const generated = @import("generated");
        \\const EffectId = generated.EffectId;
        \\const SkillId = generated.SkillId;
        \\
        \\
    );

    // Effect lookup
    const effect_names = scanDir(b, "src/effects");
    appendStr(b, &content, "pub fn getEffectDefinition(effect_id: EffectId) Effect {\n");
    appendStr(b, &content, "    return switch (effect_id) {\n");
    for (effect_names) |name| {
        appendStr(b, &content, b.fmt("        .{s} => @import(\"effects/{s}.zig\").effect,\n", .{ name, name }));
    }
    appendStr(b, &content, "    };\n}\n\n");

    // Skill lookup
    const skill_names = scanDir(b, "src/skills");
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
            // The whole raylib/ directory compiles against raylib and is
            // excluded from the headless scan wholesale — the platform seam
            // is "raylib may only be imported from src/raylib/" (asserted by
            // scripts/test.sh). See DESIGN → Platform Seam.
            .directory => {
                if (std.mem.eql(u8, entry.name, "raylib")) continue;
                collectZigFiles(b, rel, list);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                // Skip the generated root itself to avoid a self-import.
                if (std.mem.eql(u8, rel, "generated_test_root.zig")) continue;
                // Skip the raylib-linked platform entry files: the test build
                // is a headless logic compile and must not pull in raylib (see
                // the native exe wiring above and the platform seam; the rest
                // of the seam lives in src/raylib/, skipped as a directory
                // above).
                if (std.mem.eql(u8, rel, "native.zig")) continue;
                if (std.mem.eql(u8, rel, "web.zig")) continue;
                list.append(b.allocator, rel) catch @panic("append failed");
            },
            else => {},
        }
    }
}

/// Generates generated_assets.zig at the PROJECT ROOT, embedding every file
/// under data/ and assets/ plus the root license files (LICENSE-*.txt) as
/// @embedFile bytes into a std.StaticStringMap keyed by project-root-relative
/// path (e.g. "data/settings.txt", "assets/world/tile.png"). This bakes all
/// shipped content into the exe so it runs from anywhere. The license texts
/// are embedded so every distributed copy carries the licenses for the content
/// it bundles (OFL 1.1 condition 2 names "machine-readable metadata fields
/// within text or binary files" as a valid carrier; CC-BY-SA likewise requires
/// the license text to accompany distributions) — a bare single-file exe has
/// no "stand-alone text file alongside" option, the text must ride inside.
/// @embedFile needs comptime-known path literals, so the
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
    collectLicenseFiles(b, &entries);

    // Sort by key for deterministic output.
    std.mem.sort([2][]const u8, entries.items, {}, struct {
        fn lessThan(_: void, a: [2][]const u8, b_inner: [2][]const u8) bool {
            return std.mem.order(u8, a[0], b_inner[0]) == .lt;
        }
    }.lessThan);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(b, &content,
        "// AUTO-GENERATED by build.zig — do not edit manually.\n" ++
        "// Embeds every file under data/ and assets/ (plus the root\n" ++
        "// LICENSE-*.txt files) as @embedFile bytes, keyed by\n" ++
        "// project-root-relative path. See DESIGN → File System & IO.\n" ++
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

/// Generates generated_sprite_metadata.zig at the PROJECT ROOT with one entry
/// per `assets/**/*.png`, keyed by sprite id (the asset path minus the
/// `assets/` prefix and `.png` suffix, e.g. `decorations/tree_1`), value =
/// pixel dimensions as `"w h"`. Dimensions are read from the PNG IHDR
/// (big-endian u32 width/height at byte offset 16) so no image decode is
/// needed. Exposed as the named module "generated_sprite_metadata" (package
/// root at the project root, like generated_assets).
///
/// This is the build-time source of sprite dimensions for shipped art: the
/// parser looks up a shipped sprite's dims here (zero I/O) and bakes them into
/// `Decoration.pixel_dims`. Custom (runtime-imported) sprites can't be in this
/// table — their dims are parsed from the PNG bytes at acquisition time and
/// stored on the decoration/type-def the same way (see AGENTS → Decorations &
/// Footprint). Re-runs every build so new/edited art is picked up.
fn generateSpriteMetadataFile(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;

    // Reuse the same walk as asset embedding, but filter to assets/*.png.
    var png_entries: std.ArrayListUnmanaged([2][]const u8) = .empty;
    defer png_entries.deinit(b.allocator);
    collectContentFiles(b, "assets", "assets", &png_entries);

    // Build (sprite_id, dims) pairs by reading each PNG's IHDR.
    var pairs: std.ArrayListUnmanaged([2][]const u8) = .empty;
    defer pairs.deinit(b.allocator);
    for (png_entries.items) |entry| {
        const path = entry[0]; // e.g. "assets/decorations/tree_1.png"
        if (!std.mem.endsWith(u8, path, ".png")) continue;
        const with_prefix = path["assets/".len..]; // "decorations/tree_1.png"
        const sprite_id = with_prefix[0 .. with_prefix.len - ".png".len];

        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(1024 * 1024)) catch
            @panic("failed to read PNG for sprite metadata");
        defer b.allocator.free(bytes);
        if (bytes.len < 24) @panic("PNG too small for IHDR");
        // PNG signature is 8 bytes, then IHDR chunk: 4 length, 4 type, 4 width,
        // 4 height — width/height are big-endian at byte offset 16 and 20.
        const width: u32 = std.mem.readInt(u32, bytes[16..20], .big);
        const height: u32 = std.mem.readInt(u32, bytes[20..24], .big);
        const dims_str = b.fmt("{d} {d}", .{ width, height });
        const id_dup = b.allocator.dupe(u8, sprite_id) catch @panic("OOM");
        const dims_dup = b.allocator.dupe(u8, dims_str) catch @panic("OOM");
        pairs.append(b.allocator, .{ id_dup, dims_dup }) catch @panic("OOM");
    }

    // Sort by sprite id for deterministic output.
    std.mem.sort([2][]const u8, pairs.items, {}, struct {
        fn lessThan(_: void, a: [2][]const u8, c: [2][]const u8) bool {
            return std.mem.order(u8, a[0], c[0]) == .lt;
        }
    }.lessThan);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    appendStr(b, &content,
        "// AUTO-GENERATED by build.zig — do not edit manually.\n" ++
        "// Pixel dimensions (from each PNG's IHDR) for every assets/**/*.png,\n" ++
        "// keyed by sprite id (asset path minus `assets/` prefix and `.png`\n" ++
        "// suffix). Values are `\"w h\"` strings. See DESIGN → Decorations &\n" ++
        "// Footprint\". Shipped sprites only; custom runtime sprites resolve\n" ++
        "// their dims from the PNG bytes at acquisition time.\n" ++
        "const std = @import(\"std\");\n\n" ++
        "pub const map = std.StaticStringMap([]const u8).initComptime(.{\n");
    for (pairs.items) |pair| {
        appendStr(b, &content, b.fmt("    .{{ \"{s}\", \"{s}\" }},\n", .{ pair[0], pair[1] }));
    }
    appendStr(b, &content, "});\n");

    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "generated_sprite_metadata.zig",
        .data = content.items,
    }) catch @panic("failed to write generated_sprite_metadata.zig");

    return b.addModule("generated_sprite_metadata", .{ .root_source_file = b.path("generated_sprite_metadata.zig") });
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

/// Adds every root-level LICENSE-*.txt to the embed entries (scanned, not
/// hardcoded — a new root license file lands embedded automatically without
/// touching build.zig). Keys are the bare file names (project-root-relative
/// paths, same as collectContentFiles). See generateAssetsFile's doc comment
/// for why the license texts are embedded.
fn collectLicenseFiles(
    b: *std.Build,
    entries: *std.ArrayListUnmanaged([2][]const u8),
) void {
    const io = b.graph.io;

    var dir = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch
        @panic("failed to open project root for license embedding");
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch @panic("failed to iterate project root")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "LICENSE-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        // `entry.name` dies at the next iter.next() — copy it into the build
        // allocator (collectContentFiles' b.fmt does the same implicitly).
        const name = b.dupe(entry.name);
        entries.append(b.allocator, .{ name, name }) catch @panic("append failed");
    }
}

/// Scans a directory for .zig files, excludes the given interface files,
/// and returns sorted file stems (e.g. "slice" from "slice.zig").
fn scanDir(b: *std.Build, dir_path: []const u8) []const []const u8 {
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
