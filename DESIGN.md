# Ziglop - DESIGN

Settled subsystem design: architecture, invariants, the "why X is shaped this
way." Read on demand when you need the design behind something already built -
not every session. This file is the home for settled design prose; AGENTS.md
holds the "how to work here" rules and points here via the Subsystem Map. See
AGENTS.md → Documentation for the four-file lifecycle (open question → TODO;
settles → DESIGN; task completes → DONE). A fact lives in ONE place; AGENTS
never restates design - it points.

**Track the cost, not just the decision.** A settled decision's non-obvious
LIMITATION or downside belongs inline with the decision (a "Known limitation"
line or footnote). A decision that reads as clean in DESIGN can hide a real
cost (e.g. the InputBindings full-replace overlay silently shadowing new
default bindings for existing installs) until someone hits it. If a choice
trades a desirable property for another, say so at the decision site - don't
make the reader re-derive the tradeoff. A limitation that later becomes
unacceptable is the seed of the next slice; leaving it unrecorded means the
next session meets it as a surprise instead of a known.

<!-- doc index: begin -->
## Index

- [Platform Seam (raylib)](#platform-seam-raylib)
  - [SDF text outline (ALL text - plain and outlined)](#sdf-text-outline-all-text---plain-and-outlined)
  - [Outline stripe shader (marching outlines)](#outline-stripe-shader-marching-outlines)
  - [Allocator rule for emscripten (no page_allocator on web)](#allocator-rule-for-emscripten-no-pageallocator-on-web)
  - [Web audio onset latency (the ScriptProcessorNode queue watchdog)](#web-audio-onset-latency-the-scriptprocessornode-queue-watchdog)
  - [Diagnostics](#diagnostics)
- [Audio](#audio)
- [Animation](#animation)
  - [The replay-purity invariant (why the clock is read in `frame()`, not handlers)](#the-replay-purity-invariant-why-the-clock-is-read-in-frame-not-handlers)
  - [The animation clock](#the-animation-clock)
  - [Frame rate](#frame-rate)
- [Replay & Side Effects](#replay--side-effects)
- [Versioning](#versioning)
- [Logging & Replay](#logging--replay)
  - [Spawn-relative coordinates (the parse-time normalization)](#spawn-relative-coordinates-the-parse-time-normalization)
  - [Session-log bundle (the cross-session artifact)](#session-log-bundle-the-cross-session-artifact)
- [Determinism & Tiebreaking](#determinism--tiebreaking)
- [Input](#input)
  - [Escape overlay chain](#escape-overlay-chain)
  - [Console input (stdin - a scripted input channel, TAS-shaped)](#console-input-stdin---a-scripted-input-channel-tas-shaped)
- [Error Handling](#error-handling)
  - [Recoverable error surface (the popup)](#recoverable-error-surface-the-popup)
  - [Three contexts for recoverable failures](#three-contexts-for-recoverable-failures)
  - [B-simple (per-dispatch recording, not transactional)](#b-simple-per-dispatch-recording-not-transactional)
  - [Crash dump (panic → session log)](#crash-dump-panic--session-log)
- [File System & IO](#file-system--io)
  - [File source (one unified source, session-resident)](#file-source-one-unified-source-session-resident)
  - [Embedding](#embedding)
  - [Persistent path](#persistent-path)
  - [Web storage model (session-scoped in-memory storage + Import/Export Game)](#web-storage-model-session-scoped-in-memory-storage--importexport-game)
  - [Autosave](#autosave)
  - [Raylib seam](#raylib-seam)
  - [Web save export (browser download)](#web-save-export-browser-download)
  - [Load-save browser + web save import](#load-save-browser--web-save-import)
  - [Modding by shadowing (side effect, not a designed feature)](#modding-by-shadowing-side-effect-not-a-designed-feature)
  - [Migration (done)](#migration-done)
  - [Settings ownership (loadSettings is self-owned)](#settings-ownership-loadsettings-is-self-owned)
  - [Reconstruction cache (deterministic replay over mutable files)](#reconstruction-cache-deterministic-replay-over-mutable-files)
  - [Config grammar (per-format section headers + counted layouts)](#config-grammar-per-format-section-headers--counted-layouts)
- [Custom Missions & Online Services](#custom-missions--online-services)
  - [Dreams (custom missions in play)](#dreams-custom-missions-in-play)
  - [Browser (the custom-mission selector)](#browser-the-custom-mission-selector)
  - [Content identity](#content-identity)
  - [Turn counters + author medals](#turn-counters--author-medals)
  - [Validation replay (the mission-dir artifact + personal best)](#validation-replay-the-mission-dir-artifact--personal-best)
  - [Balance bounds (parse-time, warn + clamp)](#balance-bounds-parse-time-warn--clamp)
  - [Custom-asset paths (the id IS the location)](#custom-asset-paths-the-id-is-the-location)
  - [Custom-asset dimensions (warn + degrade, never reject)](#custom-asset-dimensions-warn--degrade-never-reject)
  - [Auth & the server seam (deferred)](#auth--the-server-seam-deferred)
- [Campaigns & the Campaign Editor](#campaigns--the-campaign-editor)
  - [The graph model](#the-graph-model)
  - [Content identity (uuids everywhere; SUPERSEDES the names-as-references settle)](#content-identity-uuids-everywhere-supersedes-the-names-as-references-settle)
  - [Uuid→dir resolution (scan-based loading)](#uuiddir-resolution-scan-based-loading)
  - [The editor save model (in-place identity, official-origin forks)](#the-editor-save-model-in-place-identity-official-origin-forks)
  - [File formats (each change bumps its per-type file_format_version)](#file-formats-each-change-bumps-its-per-type-fileformatversion)
  - [Campaign content paths (content-root-relative, one shape)](#campaign-content-paths-content-root-relative-one-shape)
  - [The map coordinate model](#the-map-coordinate-model)
  - [Discovery + travel (the world map's gameplay)](#discovery--travel-the-world-maps-gameplay)
  - [Campaign switching (the viewing model)](#campaign-switching-the-viewing-model)
  - [Edge geometry (loops, dangling stubs, parallels)](#edge-geometry-loops-dangling-stubs-parallels)
  - [The map surface (the world-map overlay's build)](#the-map-surface-the-world-map-overlays-build)
  - [The editor-state split (settled: a parallel CampaignEditor)](#the-editor-state-split-settled-a-parallel-campaigneditor)
  - [The campaign editor](#the-campaign-editor)
  - [The campaign editor surface (settled requirements)](#the-campaign-editor-surface-settled-requirements)
  - [The hub editor surface (settled requirements)](#the-hub-editor-surface-settled-requirements)
  - [Known limitations](#known-limitations)
- [Clones (clone system)](#clones-clone-system)
- [Gear Upgrading (the upgrade economy + hub vendor panel)](#gear-upgrading-the-upgrade-economy--hub-vendor-panel)
  - [The income model (extracted from the clone design)](#the-income-model-extracted-from-the-clone-design)
  - [The anchors](#the-anchors)
  - [The cost ladder (the mid-game segment)](#the-cost-ladder-the-mid-game-segment)
  - [The tail + tier frontier (75% → 100%)](#the-tail--tier-frontier-75--100)
  - [Drops: found gear is pre-bought rungs](#drops-found-gear-is-pre-bought-rungs)
  - [The surface: vendor NPC + two-column panel (wiring deferred)](#the-surface-vendor-npc--two-column-panel-wiring-deferred)
  - [Audit identities (the tuning tools)](#audit-identities-the-tuning-tools)
  - [Post-game](#post-game)
- [Post-game Rewards & Cosmetics (decoration base-builder + weapon skins)](#post-game-rewards--cosmetics-decoration-base-builder--weapon-skins)
  - [Overflow guard (saturating material adds)](#overflow-guard-saturating-material-adds)
  - [Hub decoration customization (central hub only)](#hub-decoration-customization-central-hub-only)
  - [Weapon skins (weapons only, for now)](#weapon-skins-weapons-only-for-now)
  - [Pricing: a static tier ladder (the "keeps up" design)](#pricing-a-static-tier-ladder-the-keeps-up-design)
- [Architecture](#architecture)
  - [Modal overlays (pause + shield pattern)](#modal-overlays-pause--shield-pattern)
  - [Level Editor (core + UI + save/export + editor browser landed)](#level-editor-core--ui--saveexport--editor-browser-landed)
- [Testing](#testing)
  - [The four bug classes](#the-four-bug-classes)
  - [Tiers - where tests live](#tiers---where-tests-live)
  - [Assertion patterns (the anti-churn core)](#assertion-patterns-the-anti-churn-core)
  - [Deletion policy](#deletion-policy)
  - [Rejected: coverage matrix (event variant → has ≥1 test)](#rejected-coverage-matrix-event-variant--has-1-test)
- [Decorations & Footprint](#decorations--footprint)
  - [Occlusion inset (readability for overhang)](#occlusion-inset-readability-for-overhang)
- [Entity & UI Coloring](#entity--ui-coloring)
- [Memory & Budget](#memory--budget)
  - [Asset memory (from the Unity project audit)](#asset-memory-from-the-unity-project-audit)
- [UI Framework](#ui-framework)
  - [UI state classification (GameState vs UiState)](#ui-state-classification-gamestate-vs-uistate)
  - [Entity inspect](#entity-inspect)
  - [Tips overlay](#tips-overlay)
  - [Settings screen](#settings-screen)
  - [Text input widget](#text-input-widget)
<!-- doc index: end -->

## Platform Seam (raylib)

- raylib is linked into the native AND web exes (never the test build). Keep
  it out of the test build by never importing raylib from any file the
  test-root scan pulls in.
- **Untextured shape drawing: plain `drawLineEx`/`drawRectangle`
sequences, never interleaved with `drawCircleV`, and no big
`drawTriangleStrip` submissions** (the curve-batching lesson, twice
learned): (a) every `drawCircleV` switches the batch to QUADS + binds +
unbinds the shapes texture - a batch flush each way, and the map views
once drew one per bezier sample (~5000 flushes/frame, 6 fps debug / 33
fast-release on a large graph); consecutive same-mode `drawLineEx`
submissions batch into ONE draw entry, so the lines alone were never the
cost. The join + end-cap jobs the circles did are handled by drawing each
segment EXTENDED by half its thickness at both endpoints (overlap fills
the join notches; the wider outline layer extends past the inner stroke's
end as the squared cap) - no extra primitives, no flushes. (b) Consolidating a multi-part shape into ONE large untextured
`drawTriangleStrip` (98 points per arrow) RENDERS on small graphs and
VANISHES in real sessions in a way that resisted two falsified theories
(leftover-texture-state, batch-buffer-rollover) and a falsified
shapes-texture-bind "fix" - the one-strip approach is abandoned (the
record is in DONE.md); the short per-segment quads always rendered.
The pre-strip code's fps was fixed by (a) alone. Map edges now sidestep
the class entirely - the baked-arrow rework draws each edge as ONE
rotated TEXTURED quad (campaign_geometry's baked-arrow section), the
submission class every sprite rides; the rules above govern the
fallback + hover-rim path only.
- `src/main.zig` stays raylib-free. The game loop is platform-agnostic and
  SPLIT into a shared per-frame core + a thin platform driver:
  - `frame(backend, *FrameState)` is the deterministic core: poll input,
    compute camera, drain events up to a 10ms budget (see below), maybe
    render. NEVER yields/sleeps - scheduling is the driver's job. Called by
    BOTH platforms, so gameplay outcome is identical across native and web
    (event order + real-clock wait deltas match; only wall-clock drain
    duration differs).
  - `gameLoop(...)` is the NATIVE driver: a blocking `while (!shouldClose())`
    that calls `frame()` each iteration and yields (`backend.waitTime(0.1ms)`)
    when idle. The WEB driver (web.zig) replaces this with
    `emscripten_set_main_loop_arg(callback, ...)` - the browser schedules rAFs
    and handles yielding, so no sleep/asyncify.
  - `FrameState` holds the per-session mutable state that lives across frames:
    `history`, `previous_view_state`, `frame_arena`, `last_render_time`.
  The backend is duck-typed with `shouldClose()`, `deltaMicroseconds()`,
  `pollInput() PlatformInput`, `render(ViewState, ViewportSize)`, plus timing
  helpers (`realClockMicroseconds`, `renderIntervalMicroseconds`, `waitTime`,
  `applyVsync`). Entry is `pub fn run(backend, *SessionSetup)` - the caller
  builds the `SessionSetup` (config + `FrameState`) via `session_setup.zig`
  before calling `run`.
- **Render target resolution** - the offscreen `RenderTexture` size is
  DECOUPLED from the 4K design space (`types.reference_width/height`). All
  layout/view math lives in 4K reference space; the backend draws into a
  separate, possibly smaller target (the `render_resolution` setting -
  `types.RenderResolution`, a 720p/1080p/1440p/2160p preset enum, default
  1080p) via a `beginMode2D(Camera2D)` camera zoom (`render_width /
  reference_width`) that auto-scales every draw call down - no per-call-site
  changes. The target is then blitted to the window letterboxed via a
  `blitTransform` (render-dims → window), separate from the pointer's
  `viewTransform` (reference 4K → window, used to map clicks back into the
  design space the game thinks in). Lowering the render target cuts fill rate
  (the dominant cost on fill-rate-limited GPUs - a level-visible 4K target
  can cap uncapped FPS at ~60 on an old integrated GPU; 1080p is 4× less
  fill). All presets share the reference's 16:9 aspect ratio
  (comptime-checked over the enum in types.zig) - the camera zoom is uniform,
  so a mismatched aspect would squish content. Higher presets sharpen SDF
  text for free (glyphs rasterize into the target at target resolution).
  **Runtime apply:** the setting is LIVE - `frame()`'s diff-and-apply
  (`SessionState.last_applied_render_resolution`
  snapshot) calls `backend.applyRenderResolution`, which creates the NEW
  target first and unloads the old one only on success. On apply failure
  (`loadRenderTexture` errors - GPU texture-size limits on weak hardware)
  the backend keeps its old target, the setting REVERTS to the
  currently-running preset (dirty-marked so the revert persists) and the
  pending-error popup names both presets - recoverable-class handling, no
  retry loop (setting now matches the snapshot; the user's next click on
  the failed preset is the only re-attempt). The backend creates its target
  at the default before settings load (it's passed into
  `createSessionSetup`), so the snapshot starts in sync and a default
  setting costs no first-frame swap; a non-default setting swaps on frame
  one. `beginMode2D` does NOT affect `clearBackground`
  (clears the full target regardless of matrix), so it runs before the camera
  block.
- The drain is BUDGET-DRIVEN: `frame()` calls `update()` repeatedly while the
  stack is non-empty, no wait is active, and <10ms has elapsed - so a
  multi-event drain completes within a single frame instead of one event per
  iteration (the old shape). This keeps web responsive (a 100-event drain
  would otherwise take 100 rAFs ≈ 1.6s) and improves native too (the window
  stays responsive during a big drain instead of blocking the main thread).
  Rendering is gated to a real-clock interval (vsync → monitor refresh rate,
  or 1/render_fps_cap, or 0 = uncapped) and SKIPPED while a drain is in
  progress (stack non-empty, no wait): vsync (`swapScreenBuffer`) blocks the
  thread for a full refresh, so rendering every drain iteration would
  frame-lock the drain. We render only when the drain completes (stack
  empties) or pauses (a wait is active). Gameplay logic drains as fast as the
  CPU allows between renders; waits use real-clock deltas (`rl.getTime`, not
  `getFrameTime`) so turn-flow pacing is framerate-independent. The native
  driver's idle/wait yield (`waitTime(0.1ms)` when the stack is empty OR a
  wait is active) avoids 100% CPU spin while keeping ~0.1ms input latency;
  the web driver doesn't yield (the browser's rAF IS the yield).
  CAVEAT: a very long non-wait drain (thousands of events) would show nothing
  until it ends - not a concern for current workloads; revisit if a long-drain
  feature lands (see TODO PACING).
- `pollInput()` reads edges FIRST, then pumps (`rl.pollInputEvents()` after).
  raylib's PollInputEvents copies `previous = current`; on web, events arrive
  async via JS callbacks between frames (current is already set on entry), so
  pumping before reading would erase the edge (current == previous → no
  press detected). Read-then-pump works on both platforms (native gets ~1
  iteration of latency at the uncapped speed, negligible).
- Files under `src/raylib/` are the ONLY ones that `@import("raylib")`
  directly (`native.zig` and `web.zig` import `raylib/backend.zig`, not
  raylib). The directory owns the window, the real-clock
  (`rl.getTime` → microseconds for deltas + render gating), input polling
  (`pollInputEvents` each poll, independent of rendering), and rendering. Built
  with `SUPPORT_CUSTOM_FRAME_CONTROL` so `endDrawing()` only flushes the render
  batch - we call `swapScreenBuffer()` (vsync paces there) and `pollInputEvents()`
  ourselves, so the uncapped loop owns event polling. Without this,
  `endDrawing()`'s built-in `PollInputEvents` eats input events that accumulate
  during the vsync block (lost clicks).
- Rendering: all content is authored in the reference resolution
  (`types.reference_width` x `reference_height`). render() draws it 1:1 into a
  reference-sized `RenderTexture`, then blits that to the window LETTERBOXED
  (aspect-preserving, centered). Element `Color` is passed as raylib's
  DrawTexturePro tint - that multiply IS the grayscale×color theming path.
  Textures are lazy-loaded from `assets/<sprite_id>.png` and cached; MISSING art
  draws a magenta box (dev-friendly) instead of failing fast - the one place we
  deliberately don't panic, since absent art is a normal in-progress state.
  The UI paths draw the box at the element's rect; the world paths
  (drawWorldSprite / drawSpriteDrawable / floating icons) draw it at the
  drawable's own rect - source-rect or icon dims when known, else the
  one-tile `types.sprite_grid_tile_pixels` fallback (the same dims the
  loaders' unresolvable-art warnings describe).
- The reference↔window letterbox transform lives in one place
  (`viewTransform()`): render() uses it to blit, pollInput() inverts it to map
  the pointer back into reference space. Keep them in sync via that helper.
- `src/native.zig` is the native exe root (`pub fn main`): sets up allocator/IO/
  window/persistent-dir, then calls `main.run` with a `RaylibBackend`. Drives
  the shared `frame()` via a blocking while-loop (the native driver).
- `src/web.zig` is the web (emscripten) exe root: mirrors native but mounts
  the IN-MEMORY persistent dir (MEMFS at /ziglop - browser storage is
  never touched; see File System & IO → Web storage model) and drives
  `frame()` via `emscripten_set_main_loop_arg` (the browser schedules rAFs;
  no sleep/yield, no asyncify). The web build itself lives in
  build.zig + `scripts/web.sh` (AGENTS → Build & Test).
- **WebGL 2 (GL ES 3.0), not WebGL 1** - the web raylib dependency sets
  `opengl_version = .gles_3` in build.zig (raylib-zig's auto-default for
  emscripten is WebGL 1). Two reasons, both settled:
  - WebGL 1 forbids mipmaps on non-power-of-two textures, and MOST of our
    art is NPOT (512x640 entities, arbitrary custom-mission assets) - the
    sprite-mipmap smoothing pass would break most art on web under WebGL1.
    (WebGL2/ES3 derive an effective RGBA8 internal format from our RGBA
    uploads, so `glGenerateMipmap` is legal for all of them.)
  - GLSL ES 3.00 has `fwidth`, so the SDF text shader gets adaptive
    antialiasing on web, same as desktop - one shader shape, no fixed-
    smoothing fallback variant.
  Browser floor moves to Safari/iOS 15 (Sept 2021); every evergreen desktop
  browser has had WebGL2 since 2017. Accepted: a mouse-driven tactical
  game's web audience is desktop browsers. WebGL2 refuses mipmaps on the
  SDF atlas's LUMINANCE_ALPHA format (unsized, not color-renderable) - that
  atlas stays mip-free by design, so the refusal is self-enforcing.
- **Sprite-mipmap smoothing (DONE)** - the harsh world-asset edges below
  1:1 zoom were undersampled bilinear minification: bilinear only reads
  the 2x2 texels nearest the sample point, correct at 2:1 (aligned box
  filter) and increasingly lossy past it (default zoom 50% x 0.5 renderScale
  = 1/4 source scale on a 1080p target). Fix (landed): `enableTrilinearMipmaps`
  (`genTextureMipmaps` + `.trilinear`) at the two `TextureStore` upload sites -
  sprite textures + generated outline/inset masks - covering shipped +
  shadowed + custom-mission art uniformly at the one choke point (+33% VRAM,
  GPU-side build, premultiplied alpha box-filters correctly; magnified/1:1
  draws still sample the base level). The render-target blit stays
  bilinear; `render_resolution` above the window remains the explicit
  supersampling option. SDF-for-art (alpha-channel distance fields) was
  considered and rejected: silhouette-only, breaks soft-alpha art, and its
  win is magnification - the pipeline never draws world art above 1:1.
- **Sprite-pass LOD snap (DONE)** - trilinear's residual weakness: at a
  NON-dyadic minification the fractional blend over-blurs (zoom 0.75 on a
  1080p target sits at LOD 1.41 → 41% of the heavily-averaged level 2 mixed
  in → the "washed out" zoom; which zooms wash depends on the render
  preset). Fix (landed): the backend's sprite-pass shader - raylib's default
  batch fragment shader + an `lodBias` uniform - snaps mip selection to the
  SHARPER adjacent level for the frame's discrete camera-zoom x render-preset
  combo (`spriteLodSnapBias`; 0 at exact powers of two, so on-level combos
  are untouched). Residual cost: the sharper level is undersampled by up to
  2^frac (≤1.5x across the combos) - mild sparkle on fine detail instead of
  uniform blur. Scope granularity: one scope for the text-free world layers,
  per-item scopes where text can draw mid-pass (raylib's endShaderMode
  restores the DEFAULT shader, so a scope spanning an SDF text draw would
  silently lose the bias); UI elements draw sprites before text, so
  per-element scoping is exact. Shader compile failure degrades to plain
  trilinear (no scope). The exact-filter escalation path (software
  box-prefiltered variant textures per zoom level, alias-free AND sharp at
  every combo) was considered and deferred - not worth the VRAM + plumbing
  unless the snap's residual sparkle ever bothers in practice.
- All raylib-linked files (`native.zig`, `web.zig`, everything under
  `src/raylib/`)
  are excluded from the test-root scan in `build.zig` (`collectZigFiles` -
  the whole `src/raylib/` directory is skipped). If
  you add another raylib-linked file, put it under `src/raylib/` (or exclude
  it too).
- raylib key ids are emitted in Web `KeyboardEvent.code` form (`KeyZ`, `Escape`,
  `Digit1`, `ControlLeft`, ...) to match `data/default_settings.txt` bindings.
- Coordinate space: `pollInput` reports the viewport AS the reference
  resolution and maps the pointer into reference space (inverse letterbox), so
  the whole game - UI hit-testing and screenToTile alike - works in reference
  coordinates.
- **Two cameras per frame.** `frame()` computes an INPUT camera (pre-update,
  reflecting the previously-rendered view - the player clicks against what's
  on screen) and a RENDER camera (recomputed post-update, before `view()`, so
  it tracks the state being drawn). Without the recompute, a move completed
  this frame draws the player at the new position under a camera still
  centered on the old one - a one-frame glitch. Both go through
  `view.computeCamera(state, zoom, pan, view_region)` so they never drift relative to each
  other or to the pan offset.
- **Camera clamping** (levels/hubs and the editor viewport).
  `computeCamera(state, zoom, pan, view_region)` clamps the player-centered
  (+panned) camera into a VIEW REGION (`view.cameraViewRegion`: reference
  space, bounded vertically by the top/bottom bars, from the left by open
  middle panels, null elsewhere). Two rules with different applicability:
  - **Level-flush bounds** (pan included): the visible world window
    stays inside the level's tile bounding box (levels are non-rectangular;
    the bbox of `level_tiles`/`hub_tiles` is the "level rectangle"; the
    editor uses the ACTIVE level's `level_tiles`), so the
    AUTOMATIC camera never shows void beyond an edge. A deliberate pan
    gets `camera_pan_void_tiles` (4 tiles, tunable) of wiggle: it may push
    that much void past an edge before the clamp stops it, so the edge
    doesn't feel like a hard wall. On an axis where the level fits inside
    the region, the level is CENTERED as a whole (and a pan wiggles ±4
    tiles around the centered position instead of being a no-op).
  - **Player-margin band, automatic camera only** (`pan == null`): the
    camera may not deviate from the player-centered position further than
    (region half-extent − `camera_edge_margin_tiles`, a tunable 2-tile
    clearance). Sequential clamping (flush first, then margin) yields the
    intended framing: shift toward the flush bound as far as possible
    WITHOUT pushing the player past the margin - a player at the level's
    left edge sheds most of the left void but keeps exactly 2 tiles of
    clearance. A pan offset suspends the margin on BOTH axes (the point of
    panning is to look away from the player); it clears on player move /
    screen transition, so normal play always has the margin.
  - **Panel fallback**: when the panel-occupied remainder is narrower than
    the margin band (4 tiles at the current zoom) - the fully-covered
    screen - the region ignores panels entirely ("act as if none open").
  The clamp is pure math on the final camera (pan included); the pan solve
  in `handleCameraPan` passes `view_region = null` for its reference so pan
  stays exact in the level interior, with resistance only at the edges.
  **Editor viewport**: same band as the game (the top row + tool palette
  bound it vertically) at FULL width - the sidebars and pickers are
  deliberately ignored (they never reframe the camera). The clamp shapes
  the player_start-centered framing exactly like gameplay (margin band
  around the '!' marker, flush bounds, small levels centered as a whole),
  but a deliberate pan is COMPLETELY free there - no flush bounds, no
  wiggle. Unpanned = clamped framing; panned = roam anywhere; the clamp
  resumes when the pan clears. The clamp bounds come from
  `Editor.clamp_bounds` - a SNAPSHOT of the active level's tile bbox,
  refreshed ONLY when the active level switches (`open_editor` both
  branches, `editor_set_active_level`, `editor_add_level`,
  `editor_delete_level` clamping onto new content - `refreshEditorClampBounds`,
  the single refresh site). Mid-edit tile changes deliberately never
  refresh it: painting/erasing tiles changes the live bbox but must not
  reframe the camera mid-edit (the author's viewport stays put; the next
  level switch re-clamps). Because the refresh rides the same events, undo
  /redo + replay reproduce the snapshot by construction. Null = the level
  was empty at snapshot time - the unclamped editor camera. Pan clearing
  keys on `view.cameraRecenterKey` (player position + the
  editor's active level index) so a level-tab switch recenters even when
  two levels share a player_start (fresh levels all come from one
  template). During playtest/validate the editor state persists on a
  `.level` screen - the live level takes precedence everywhere, so the
  run keeps the level clamp + wiggle, not the editor's free pan.
  Panel widths come from `middlePanelWidth` (shared with
  `buildMiddlePanels`) so layout and clamp region can't drift apart.
- **Camera pan (right-drag)** is transient view state on `SessionState`
  (`camera_pan` + `camera_pan_anchor` + `camera_pan_press`), off `GameState`
  - replay-safe by construction (like `tile_cursor` / the animation clock).
  Levels/hubs + the editor viewport; cleared on player move, editor
  level-tab switch, or screen transition - the `cameraRecenterKey` check in
  `update()`. In the editor the camera centers on the active level's
  `player_start` (`playerPosition` editor arm), so pan is relative to that.
  `handleCameraPan` (input_gestures.zig) runs anytime (mid-wait /
  mid-turn). A right-press records the press position + the world point
  under it (sub-tile float precision via `input.floatWorldPoint`, the float
  inverse of the camera transform); the pan ENGAGES only once the pointer
  moves beyond the shared `ui.drag_threshold_pixels` (the one threshold
  every drag gesture uses - a sub-threshold wiggle pans nothing, keeping
  clean right-clicks clean), then solves for the camera that keeps the
  pressed point under the cursor (press-anchored, so the grabbed point
  sticks to the cursor). Pan-start is suppressed over blocking UI
  (`blockingElementAt`). Right mouse is the pan button (cancel is
  Backspace only).
- `build.zig` also generates `src/generated_lookups.zig` and the `generated`
  module (SkillId/EffectId enums) by scanning `src/skills/` and `src/effects/`,
  plus `generated_sprite_metadata.zig` (pixel dims from PNG IHDR for every
  shipped `assets/**/*.png`, keyed by sprite id) and `generated_assets.zig`
  (embedded content map). All are gitignored.

### SDF text outline (ALL text - plain and outlined)

ALL text renders via a **signed distance field** pipeline: a glyph atlas
whose texels encode distance-to-glyph-edge (positive inside, edge at alpha
128) instead of coverage, plus a fragment shader that thresholds the field
into fill + outline band. Plain text is the SAME shader with a zero
outline width (the band collapses; a transparent outline color makes it
contribute nothing), so every string is resolution-independent - the
pre-unification plain path (runtime coverage atlas, bilinear-sampled from
a fixed 128px base, undersampled 2.5-5:1 at a 1080p target) is gone
entirely (see the fallback policy below). One shader-driven `drawTextEx`
per string - no per-string CPU raster, no dilation pass, no texture cache
(the pre-SDF approach was an 8-direction drop-shadow ring: 9 draws, fuzzy
at non-integer offsets, no antialiased outer edge; it remains the outlined-
text degradation on the default-font fallback).

Key pieces (`src/raylib/text.zig`):

- **Build-time atlas**: `tools/sdf_atlas_generator.zig` is a HOST tool
  linking raylib as a library (no window - SDF generation is pure CPU) that
  bakes the atlas via the SAME raylib calls the runtime once used
  (`loadFontData(.sdf)` + `genImageFontAtlas`) - zero metric drift. The blob
  (header + per-glyph metrics + atlas bytes) is embedded via the
  `generated_sdf_font` module; `initSdfTextOutline` parses it (microseconds)
  and assembles the `rl.Font` manually. This moved ~1.4s (release) of
  startup SDF generation to build time.
- **Encoding range**: raylib's SDF defaults encode only ±2px of distance -
  far too little for 8px outlines. The generator's raylib dep is compiled
  with `-DFONT_SDF_CHAR_PADDING=22 -DFONT_SDF_PIXEL_DIST_SCALE=6.0`
  (±21 atlas px - covers an 8px outline at 56px+, clear of the clamp
  floor). `sdf_pixel_dist_scale`/`sdf_char_padding` in
  the backend's SDF constants must stay in lockstep (a `@compileError` + blob
  validation guard this; the blob carries its baked params and mismatches
  degrade to the fallback).
- **Outline-width clamp** (`sdf_max_outline_atlas_pixels`): `drawSdfText`
  clamps the requested atlas-px width to the encodable range (floor −2
  for the fwidth window). WHY: a request whose shader fade window
  `[−W−aa, −W+aa]` dips to the field's clamp floor makes every clamped
  texel evaluate band ≈ 0.5 - and clamped texels are exactly the rect-
  CORNER diagonals (true ink distance ~30px where the rect is only 22px
  padded per axis), so the result was ghost squares at each glyph quad's
  corners (seen on the 48px material-count labels: 8·128/48 ≈ 21.3, right
  at the floor). A clamped request draws a marginally thinner outline
  (7.2px instead of 8 at 48px) - never squares. Outlined text below
  ~44px would need the range widened instead (generator constants + blob
  regen); nothing demands that today.
- **Shader**: embedded GLSL (3.30 on desktop, 3.00 es on web - both
  variants in the backend, selected comptime; both use `fwidth`, since the
  web context is WebGL 2). Thresholds the decoded field:
  `d >= 0` fill, `[-outlineWidth, 0)` outline band, `fwidth`-sized
  antialiasing. Straight
  alpha out (raylib blends premultiplied-input as straight; the old
  raylib SDF example's shader outputs the same shape). A zero outline
  width MUST pair with a transparent outline color: the collapsed band
  sits exactly on the fill edge (band == fill), and an opaque one would
  source-over-composite black into the antialiased fringe
  (outA = 2fa − fa² - a dark, over-bright edge on every glyph).
- **GRAY_ALPHA, not GRAYSCALE**: the runtime texture is reconstructed as
  GRAY_ALPHA (gray=255, alpha=SDF) because raylib swizzles GRAY_ALPHA to
  `(r,r,r,g)` on desktop GL - a grayscale texture samples `.a` as constant
  1.0 and renders solid boxes (this bit us once; the blob stores only the
  alpha channel and the runtime interleaves).
- **Codepoint set (full font coverage)**: the atlas bakes EXACTLY the
  codepoints the shipped font's cmap maps - no hand-maintained codepoint
  list anywhere. `src/font_codepoints.zig` (raylib-free TTF cmap parser:
  format 4 + 12, standard best-subtable preference, notdef and NUL
  excluded; unit-tested against hand-built fixture TTFs) feeds the
  generator at build time; `src/font_codepoints_tests.zig` pins the
  shipped font's contract (full ASCII + the punctuation set) against the
  embedded bytes. `max_atlas_codepoints` (1024) is the shared bound: the
  blob parser's sanity guard + the generator's build-time gate. The
  measurement seam follows: `ui.FontMetrics` carries the font's non-ASCII
  advances (filled once at init, sorted, binary-searched by
  `measureSpanWidth`; ASCII rides the fixed 95-entry array; a codepoint
  the font lacks measures a 0.5em approximation). Size budget: 95 → 407
  glyphs = blob 2.1 → 8.4 MB, atlas 2048×1024 → 4096×2048 (release exe
  +6.6 MB, wasm +6.4 MB). The 4096-wide atlas exceeds WebGL2's GUARANTEED
  minimum MAX_TEXTURE_SIZE (2048): on such a device the upload fails and
  text degrades to the default-font fallback below.
- **Fallback policy**: SDF init failure falls back to raylib's DEFAULT
  bitmap font - borrowed (raylib-owned, never unloaded), decided ONCE at
  init, fixed for the session: legible ASCII, no outline band (outlined
  text degrades to the 8-direction shadow ring), straight-alpha so
  slightly bright under the premult blend. `fontMetrics` reads from the
  ACTIVE font so layout always measures with the advances the renderer
  draws with. An SDF font must never be drawn without its shader (texels
  are distances, not coverage). The failure sites are: blob invalid
  (near-unreachable - a build-time artifact, guarded by the comptime
  constants check + blob validation), shader compile (pre-GL-3.3 desktop
  only; WebGL2 guarantees GLSL 300 es), texture upload (a GPU with
  MAX_TEXTURE_SIZE < 4096 - see the codepoint-set budget above). The
  former intermediate fallback (a runtime coverage atlas rasterized from
  the embedded TTF) was REMOVED: it was unverifiable (raylib-only code,
  no way to force the failure short of broken hardware, excluded from
  the headless suite) and dragged its own machinery (CPU premultiply
  subtleties, the persistent-dir font shadow seam, deinit ownership) -
  complexity maintained for a promise that could never be tested. No TTF
  is read at runtime; the font file on disk feeds only the generator and
  the contract test.

### Outline stripe shader (marching outlines)

The theme-`lightest` outlines (the world tile outlines - the clickable-tile
highlight (an INSET square outline, `ui.tile_highlight_inset_divisor` =
side/16, the retired `world/tile_highlight` marching-ants sheet's band
position; the sheet was the earliest-prototype art, replaced by the
outline class), cursor, range, radius, aggro, region edges - the UI icon
halo masks, the baked-arrow hover rim (the same halo-mask class over
the arrow's rasterized silhouette), the spriteless panel-button hover
rect, and the stroked
`.solid_rect` branch = the inventory multi-salvage drag region + the editor
Select tool's icon of the tile highlight) read weakly over busy art. They
all draw through one fragment shader (`backend.zig`, the spriteLodSnapBias
pattern): the default batch shader (texel × tint) plus a diagonal
marching-stripe flip between the incoming tint (theme `lightest` at every
call site) and player gradient index 5 (the button-tint class - a
frame-level uniform; the pair chosen by eyeball over the earlier
theme-`darkest` and pure-white/black tries). The per-draw `lightest` tint
is also the compile-fail fallback look.
`s = gl_FragCoord.x - gl_FragCoord.y - phase*period` in render-target
pixels (the diagonal family + crawl direction chosen by eyeball - the two
signs in the shader source are the flip knobs); `mod(s, period) <
stripeBandWidth` flips the RGB to the dark color at the texel's own alpha
(premultiplied output - the pass draws under BLEND_ALPHA_PREMULTIPLY).
50/50 duty (period = 2 bands), hard flip, band width = `outline_stripe_band_multiplier`
(2.0) × the outline width constant × renderScale - ONE
band for BOTH outline families, zoom-independent: the crawl rate is one
period per cycle, so a shared band means a shared period - both families
march at the same size AND the same pixel speed (the first cut scaled the
world band by the camera zoom, so at the default zoom 0.5 the world
outlines crawled at half the UI outlines' speed - the observed mismatch).
The world bands therefore do NOT track the outline stroke's zoom-scaled
thickness; family uniformity beats per-family thickness matching. The
LIGHT color rides the existing per-draw tint; ALL stripe uniforms (dark
color + phase + band) are frame-level, set once per frame in `render` -
the shader has no per-scope state, the scope helpers only bind/unbind.
A compile failure degrades exactly to the pre-shader look (solid tint) -
never a crash. The SDF text outline shader is a SEPARATE pass, untouched
by this.

The phase (0..1, `ViewState.outline_stripe_phase`) is view-side, computed in
`view()` from the UNGATED `session.session_clock` stepped at
`settings.animation_fps` (8 steps per cycle - frame-quantized at the shared
animation rate, one animation system; the stripe is UI + decorative, so it
marches during pause too, options/settings menus included - see Animation
for the two-clock split). The clock wraps mod the cycle IN u64 before the f32
conversion (f32 mantissa holds only ~16.8s of microseconds). No game
state involved - no replay impact.

THE endShaderMode TRAP applies to the scopes: every draw site opens the
stripe scope INSIDE an enclosing sprite pass (`beginSpritePass`), and
`endOutlineStripeScope` must RE-OPEN that sprite pass - raylib's
endShaderMode restores the DEFAULT shader, so the rest of the world pass
would silently lose its LOD snap bias otherwise (the world layers share ONE
sprite-pass scope; see Sprite-mipmap smoothing).

**Constant outline width.** The outline family draws at ONE width -
`types.outline_thickness` (8 REFERENCE px) - CONSTANT, independent of world
zoom and of the size of the outlined thing: the world rect strokes no
longer scale by the camera zoom (the outlined thing scales, the stroke
does not), the Select icon / spriteless button rects / the footprint
picker's bars all reference the same constant, and the silhouette-hugging
halo masks COMPENSATE for the drawn scale - the band is generated at
`ceil(outline_thickness / drawn_scale)` SOURCE px (one mask per (sprite,
band) in the outline cache, keyed by a flat `"{sprite}|{band}"` string), so
the DRAWN band is the constant width at every element size. The occlusion
inset stays source-px-scaled BY DESIGN (a world-scaled shadow, not the
outline family).

### Allocator rule for emscripten (no page_allocator on web)

`std.heap.page_allocator` is **unusable on wasm32-emscripten**: it is
BrkAllocator, which grows wasm memory via the raw `@wasmMemoryGrow`
intrinsic. Emscripten's JS glue only refreshes its heap views (HEAP8/...)
and SAFE_HEAP bounds when growth goes through ITS allocator (emmalloc
sbrk → emscripten_resize_heap). A raw grow leaves the JS side stale - the
views detach (JS access to wasm memory aborts) and SAFE_HEAP keeps the old
memory size (wasm access to the grown region reports a segfault). This was
the web black-screen regression: `loadFont` duped the TTF into grown
memory and the first stbtt read tripped SAFE_HEAP.

Rule: on emscripten, ALL allocations go through libc. Transient,
untracked allocations (font bytes, crash-dump output, existence probes)
use `transient_allocator.zig` - c_allocator on emscripten, page_allocator
on native. Never call `std.heap.page_allocator` directly from shared code.

### Web audio onset latency (the ScriptProcessorNode queue watchdog)

On web, raylib's ENTIRE mixer runs inside miniaudio's `onaudioprocess`
JS callback on the MAIN thread (no SharedArrayBuffer in the build → miniaudio's
AudioWorklet path is unavailable → the ScriptProcessorNode fallback), and
each fill's mixed buffer joins the node's output queue, which drains to
the speakers at exactly 1x real time. The queue is the onset-latency
story, in two layers (both MEASURED - the onset probe instrumented the
submission moment in Zig + the fill moment in JS):

- **Inherent lead**: a healthy node schedules its fills ~1-2 buffers ahead
  of playback - ~30ms at the 1024-frame period (see below), i.e. the
  platform's base onset latency for every sound. Native has none of this
  (a real audio thread, 10ms period, instant by the same measurement).
- **Banked queue (the bug class)**: a long main-thread block (a
  mission/level load) starves the queue during the block (the clock runs
  on through silence), then the browser delivers the missed fill requests
  in a BURST - each banking ~one buffer (21ms at 1024 frames) of pre-mixed
  audio AHEAD of playback. The banked depth never drains (production and
  consumption both run 1x afterwards; the clock-ratio probe reads 1.000
  through it all), so EVERY subsequent sound plays late by the banked
  depth, permanently: measured ~2s in Debug (slow loads), ~90ms in
  Release - the reported "web audio delay", worst in combat (after the
  level load that banked it). Buffer size is irrelevant to the banked
  depth, which is why halving the buffer changed nothing.

The FIX (landed): the web driver installs a QUEUE WATCHDOG
(`web.zig`'s `installAudioLeadWatchdog`, every web build, per boot) - a
runtime property swap on the node's callback (NO raylib/miniaudio source
is touched) that watches the queue depth on every fill
(`AudioProcessingEvent.playbackTime` vs the context clock). The trip
detector is SUSTAINED ELEVATION: the lead exceeding ~60ms on 3 consecutive
fills. A banked queue lifts the lead above the healthy envelope and HOLDS
it (it never drains) - while scheduling jitter spikes are single fills,
and the tight ~0-20ms schedule a rebuilt node runs jitters -66..+35ms
around zero (measured) - persistence is the one signal separating them.
60ms sits above both schedule shapes' healthy envelopes (miniaudio's
original ~30-64ms; the rebuilt node's ~0-20ms) and below the banked depth
(~90ms release, ~2s debug); the 3-fill streak completes fast inside a
burst (fills arrive back-to-back after a block). On a trip it REBUILDS
the node: a fresh ScriptProcessorNode starts a clean schedule (measured
~0-20ms ahead - TIGHTER than miniaudio's original, so the repair lands
at better-than-baseline latency) and the stale pre-mixed queue is dropped
with the old node. The wrapper is reattached, so miniaudio's wasm-side
mixing state is untouched. Costs when it fires: the music skips forward
by the banked depth (right after a load, when a gap is least noticed)
and any sound triggered during the block is LOST rather than played
seconds late - the right trade for feel. Verified outcomes (release,
probe-verified): one trip per load, ~15-45ms onset totals after the
repair, no false trips at steady state. Known limitation (accepted,
degrades-safe): the install reads miniaudio's internal device layout
(`window.miniaudio.devices[0].scriptNode`) - a raylib upgrade that
reshapes it makes the watchdog find nothing and quietly no-op back to
the banked-queue bug, never a crash.

The device period is also tuned: raylib's default period (0) becomes a
2048-frame (~43ms) ScriptProcessorNode buffer on web (miniaudio's
browser-specific override), doubling the inherent lead. The build passes
`AUDIO_DEVICE_PERIOD_SIZE_IN_FRAMES=1024` (~21ms, build.zig's web raylib
config) - measured serviceable at 60fps (clock ratio 1.000, the main
thread services a fill every ~21ms against ~16.7ms frame gaps) with the
inherent lead halved; 512/~10.7ms would chronically starve.

The STRUCTURAL fix - miniaudio's AudioWorklet path (mixing on the
browser's audio thread; a load block becomes a silent ring-buffer
underrun that recovers instantly instead of a banked queue) - is DEFERRED
 to the web hosting milestone (TODO → Platform Layer): it needs
`MA_ENABLE_AUDIO_WORKLETS` in raylib's C build, `-sASYNCIFY` (whole-program
instrumentation: bigger + slower wasm), and SharedArrayBuffer (wasm
workers) - which requires COOP/COEP cross-origin-isolation headers from
 every host that serves the game. That tradeoff belongs with the hosting
decisions. The watchdog caps the damage until then.

### Diagnostics

Purpose: Terminal-less platform troubleshooting - getting data from
machines whose users can't debug (the friend workflow; future player bug
reports). The section set is exactly what carried the mac miscompile
hunt; extend only when a real incident asks for more.

- **The seam:** `src/diagnostics.zig` is a raylib-free `Diagnostics`
  type (append buffer + section one-shot policy + flush scheduling),
  compiled + unit-tested in the headless test build.
  `src/raylib/diagnostics.zig` is the value-gathering half: the GL-touching
  probe sites read the raw values (GL identity strings, draw state,
  render-target pixels) and record them as plain data - all `rl.*` stays
  in the raylib dir. One instance owned by `RaylibBackend`. NO
  abbreviations anywhere (`Diagnostics`, `diagnostics_file_path`).
- **Activation - a single runtime toggle:** the `--diagnostics` CLI flag,
  valid on ANY native build INCLUDING plain release (the hunt's
  structural catch-22 was "the broken build can't log" - dev-gated
  diagnostics can't capture release-only failures; the runtime flag
  lets the very binary that exhibits a bug produce its own data). Dev-
  mode builds default to active (`--diagnostics` ORs onto that default;
  web stays off - native-only). The code ships in all native builds - a
  few KB, zero writes when inactive.
- **The boot section also carries the compile status of the three
  SILENT-DEGRADE shaders** (sprite LOD → plain trilinear, outline stripes
  → solid tint, SDF text → shadow ring): a failed compile never crashes -
  the pass falls back to its pre-shader look - and nothing else surfaces
  it, so the boot line is where the degrade becomes visible (the GLSL ES
  web variant is the realistic failure case).
- **Writing - event-driven, never per frame:** sections are one-shots
  (boot once at first render; each first-draw probe once per primitive
  per session; the readback once on the frame a probe armed) - a
  handful of writes per session. A pending flush executes at the
  END-OF-FRAME safe point (after present, `flushIfPending` at the end of
  `RaylibBackend.render`), never mid-draw: observation
  work inside the draw path perturbs the observed system - the mac-
  hunt lesson. Whole-file rewrite per flush (the file is always
  self-consistent). Clean shutdown flushes anything pending; a hard
  crash loses at most the unflushed buffer (crash-time state is the
  crash dump's job, DESIGN → Error Handling → Crash dump).
- **Sections:** boot (game_version, target, window/framebuffer dims,
  render target dims, GL vendor/renderer/version/GLSL); first-draw
  one-shot probes per primitive (drawSprite, drawNineSlice - full draw
  state); render-target pixel readback at the probed destinations (the
  pipeline-stage split: pixels present in the target = present-path
  failure, pixels absent = the draw/upload failed).
- Web: out of scope for now (native-only, like today's system).

## Audio

Sound is a **side effect**, never gameplay state. Same replay-safety rule as
file writes: event handlers queue sounds gated `!replaying`, so undo/redo
scrubbing is silent. The architecture mirrors `PendingWrite`:

- **`SessionState.pending_sounds: std.ArrayListUnmanaged(SoundCue)`** (off
  the undoable GameState → replay-safe by construction; `backing_allocator`-
  backed, cleared each frame). Event handlers + input handlers call
  `session.queueSound(allocator, .id)` / `queueCue` / `queueActionSound`;
  `frame()` drains via `session.drainPendingSounds()` after the update drain
  and plays them through the backend. The `!replaying` gate is at the PUSH
  site, so replay pushes nothing.
- **Layered cues (`SoundCue`, types.zig).** Every trigger is a CUE: a
  category BASE layer plus an optional specific LAYER, played
  simultaneously; mix balance is baked into the asset files (both layers
  play at the sfx volume - no per-layer volume data). Whether the base is
  percussive and the layer ambient (or the reverse) is a per-file authoring
  choice - every file name carries its role explicitly (`*_base` /
  `*_layer`), so the naming never presumes either. Plain one-shots (damage,
  move, ...) are base-only cues. The three layered families:
  - **Skill cues** - base by `SkillType` (`skillTypeBaseSound`:
    weapon_skill→weapon_base, spell→spell_base, cantrip/enchantment/curse→
    their own `*_base` ids) + layer by `SkillId` at
    `assets/audio/sfx/skills/<id>_layer` (stem defaults to the skill's own
    id - zero declaration per skill). Queued by the `use_skill` handler.
    Missing base or layer files are SILENT - no fallbacks anywhere
    (silence is the "not authored yet" signal; the report tool lists
    every path).
  - **Button cues** - press ALWAYS plays plain `button_base_down`; release
    plays the `button_base_up` base plus the action's LAYER at
    `assets/audio/sfx/buttons/<action_snake_case>_layer`. Layer ownership is
    split by role, which is what keeps the layers from double-playing:
    the release SEAM owns the base up; the layer is owned by ONE choke
    point - `dispatchFiredActionSounds` (main.update, over
    `PlayerInput.fired_actions`, the set `applyAction` records - so
    keyboard, button, and console triggers share ONE layer queue per
    action with no click sounds: the no-click-sounds-for-keys rule). Two
    documented exclusions keep semantics feedback honest:
    `types.actionSoundUnwired` (no layer by design - the same list the
    sound report excludes) and the OUTCOME-GATED set (undo/redo,
    swap_weapons, cancel, skip, the skill slots -
    `actionLayerRidesConsumptionSite`),
    whose layer rides the CONSUMPTION site so a no-op stays silent (an
    undo with nothing to undo, a swap with both hands empty, a cancel
    with nothing prepared, a skip that never reaches its orchestrator)
    and an auto-fire slot cast plays the full
    skill cue instead. SKIP was the shipped lesson: `.skip` was missing
    from the set, so a skip queued its layer at BOTH sites - two plays
    per skip, which on fast native landed in one frame's playSounds (two
    pool entries overlapping into one louder blip - not hearable) but on
    web separated across frames (the orchestrator often drains a frame
    later) - "the skip sound repeated quickly", a web-sounding bug with
    a platform-neutral root cause. A missing entry here double-plays; the
    live-path test (input_handlers' "skip action layers exactly once")
    pins it. Skill slots: the release seam suppresses the up
    base (`types.actionIsSkillSlot`) - auto-fire's use_skill cue subsumes
    any button sound, and the prepare/unprepare path plays its own up
    base + slot layer at the consumption site. History: the
    `.change_setting`/`.edit_keybind`/`.select_settings_tab` layers
    double-played for months (the options_action top-of-switch queue +
    the arms' own queues) until the choke point collapsed the scattered
    sites - pinned headless by the dispatchFiredActionSounds test.
  - **Item-action cues** (equip / salvage / learn_skill) - the shared
    `item_base` base plus a per-action layer keyed by `ItemActionSound`
    (types.zig) at `assets/audio/sfx/items/<tag>_layer`. Queued at the
    effect sites (the `equip_item`/`salvage_item`/`learn_skill` event
    handlers - after their no-op guards, so empty-slot salvages stay
    silent).
  - **Layer caches miss-not-cached** (`skill_layer_cache`/
    `action_layer_cache`/`item_layer_cache`, keyed by SkillId/Action/
    ItemActionSound): a missing layer file is RETRIED on the next cue, so a file
    dropped into the persistent dir mid-session plays on the next
    cast/click without relaunching - the sound-designer iteration loop.
    Bases (`sound_cache`) stay eager + null-cached (they're few, and all
    shipped).
- **The sound asset overview** (`src/sound_report.zig`, a host build tool:
  `scripts/sound_report.sh` → `zig build sound-report`, run on demand -
  never part of a normal build) regenerates `sound_report.md`: every
  wired path walked off the enums (new skills/actions appear
  automatically), each with its trigger description + a status resolved
  against BOTH the shipped `assets/` tree and the persistent dir
  (`shipped (.ogg)` / `shadowed (.wav)` / `MISSING (silent)`). The
  designer's complete inventory - the truth the no-fallbacks policy makes
  exact.
- **`SoundId` enum** (types.zig) - one variant per sfx file under
  `assets/audio/sfx/` - the BASE sounds (skill-type bases weapon_base /
  spell_base / cantrip_base / enchantment_base / curse_base, the item base,
  the button base pair button_base_down / button_base_up) and the one-shots
  (move, damage, collision, pickup, skip, equip, salvage, learn_skill,
  swap_skill, menu, defeat, mission_completion, heal, stun, knockback,
  retreat, death, level_complete, aggro). Music is a stream stack, NOT a
  `SoundId`. **Sound names align with their trigger events where one
  exists** (move↔move, pickup↔pickup, collision↔collision, etc.).
  The one-shot map: `move_entity`/`move_player`→move,
  `damage`→damage (the impact cue - queued by the shared damage apply arm
  so attack- and collision-sourced hits sound identically),
  `collision`→collision (the wall crunch), `heal`→heal, `stun`→stun,
  `knockback`→knockback, `retreat`→retreat, `death`(enemy)→death,
  `death`(player)→defeat, `pickup_items`→pickup, `aggro` (every
  newly-aggroed enemy, via `activateEntity` - the one queue site all
  activation paths route through)→aggro, non-final `end_level`→
  level_complete, final `end_level`→mission_completion. The item actions
  (equip_item/salvage_item/learn_skill) are layered CUES, not plain
  one-shots - their layer keys live on `ItemActionSound`, not `SoundId`.
  Multi-hit sounds are paced on the event timeline, not by backend
  throttling: every `attack`/`collision` → `damage` pair is separated by an
  intra-hit pacing wait (see Architecture - Damage apply split), and the
  cross-chain spacing sweep lives at the push sites (TODO → Effect pacing).
  A backend per-sfx cooldown (`playSounds`) stays a last resort - never at
  trigger sites.
- **Button press/release model.** Button actions fire on mouse RELEASE, not
  press (standard UI behavior; drag-off cancels). `SessionState.pressed_button:
  ?Action` records the button under the press; release fires the action only
  if the release is over the same button. Press always queues
  `button_base_down` (plain - never layered). Release queues the
  `button_base_up` base for every action EXCEPT skill slots (see the layered
  cues bullet), and the action's layer is queued at the consumption site
  (`queueActionSound`), shared with keyboard triggers - keys get the layer
  alone (no click sounds, since no button was involved). Text-field commits
  play a plain up (no button was pressed; the commit IS the interaction).
  `pressed_button` is transient - cleared on screen transition alongside
  `ui_state`/`tile_cursor`/`camera_pan`.
- **Backend (`src/raylib/audio.zig`):** `initAudio(settings)` opens the audio
  device, loads all sfx bases via `loadWaveFromMemory` + `loadSoundFromWave`
  from the `FileSource` (never the filesystem - same seam as textures),
  loads + starts the music streams, then loads the sfx. The base cache
  (`AutoHashMap(SoundId, ?rl.Sound)`) holds loaded bases; a missing audio
  file caches null and plays nothing - no fallbacks (unlike missing
  sprites → magenta; silence is the audio equivalent of an honest
  "not authored yet"). The skill/action/item
  LAYER caches are lazy + hit-only (see layered cues). `deinitAudio` (called from
  `deinit`) unloads everything + closes the device. If the audio device
  can't open, `audio_ready` stays false and ALL audio methods no-op - the
  game runs silent, never crashes. **MUSIC LIFETIME GOTCHA:** raylib's
  `LoadMusicStreamFromMemory` (stb_vorbis) keeps a POINTER to the passed
  buffer (no internal copy), so each layer's bytes must outlive its stream -
  held per-layer in `music_layers[i].data` and freed in `deinitAudio`
  alongside the stream unload. **MUSIC-MUST-LOAD-FIRST GOTCHA:** the music
  streams must be loaded + started BEFORE the sfx. `LoadSoundFromWave`
  converts samples to the active device format; if the music stream hasn't
  initialized the audio system's state yet, the sfx convert to a stale format
  and silently never play (no error, no log - the sounds load valid,
  `playSound` is called, but no audio). The order in `initAudio` is: open
  device → load+start music → load sfx. No compile-time guard - reordering
  silently breaks sfx.
- **Layered music (intensity stack).** `music_layers: []MusicLayer` - index
  0 is the base track (`assets/audio/music/ambient`), 1..N are intensity
  layers (`assets/audio/music/ambient_layer_1..N`, probed at init until the
  first missing file, capped at 16 - the stack extends by pure asset drop,
  no code change). Each frame `frame()` projects the count of ALIVE, AGGRO'D,
  enemy-team entities (`main.countActiveEnemies`) and passes it to
  `backend.updateMusic(count, delta, settings)`: every stream advances
  (raylib requires per-frame streaming updates), each layer's tier volume
  lerps toward its target (base always 1.0; layer i ON while count >= i, at
  a descending tier volume - `musicLayerVolume`: 0.8/0.65/0.5/0.4/...), and
  the music/master settings scaling is applied per frame (sfx volume is
  per-play). The fade is ~1s real-time, so aggro/death transitions
  crossfade instead of hard-cutting. **The projection is a STATE projection,
  not an event** (like the combat log / camera): no queue, no `!replaying`
  gate - undo/redo/replay are safe by construction (scrubbing before the
  fight calms the music down for free). **AUTHORING CONSTRAINT:** all layers
  must be IDENTICAL-LENGTH, sample-aligned loops (export as stems from one
  DAW session) - raylib loops each stream independently, and only
  exact-equal lengths keep them phase-locked; a frameCount mismatch is
  reported to the diagnostics sink at load in dev builds. One base track everywhere for now
  (per-screen base tracks are a later extension); medal stingers for the
  mission-complete overlay are sfx one-shots, not layers (one per medal type
  when the medals work lands).
- **File formats (`.ogg` shipped, `.wav` accepted):** every shipped sound is
  `.ogg` (smaller embedded exe); `FileSource.readAudioFile` (file_source.zig)
  also accepts `.wav` so a persistent-dir shadow can drop WAV exports - file
  size is then the shadowing author's tradeoff, not ours (see File System &
  IO → Modding by shadowing). `.wav` is tried FIRST: the layering is
  per-path and every shipped sound's `.ogg` exists in the embedded map at
  the same relative path, so an `.ogg`-first order would always hit the
  embedded copy and a dropped `.wav` would never load. We ship no `.wav`, so
  a `.wav` candidate can only ever be a persistent-dir shadow. When both a
  `.wav` and an `.ogg` sit in the persistent dir, the `.wav` wins
  (deterministic). Applies to sfx and the music stream alike (the candidate
  policy is a FileSource concern, not a backend one).
- **Per-frame:** `frame()` calls `backend.updateMusic(count, delta,
  settings)` at the top (raylib requires it for streaming + it drives the
  intensity layers - see layered music) + `backend.playSounds(drained,
  settings)` after the drain. Sfx volume = `sound_effects_volume *
  master_volume` (per-play); music volume = `music_volume * master_volume`,
  applied to every layer per frame - volume-setting changes apply live with
  NO diff machinery (the removed diff approach's history: DONE → Audio).
- **Assets:** all audio shipped as OGG (ported from the Unity project's WAVs
  via ffmpeg). Music: `assets/audio/music/ambient.ogg` (looping, ~3.3 MB).
  SFX: `assets/audio/sfx/*.ogg` (~220 KB total). Embedding OGG (not WAV) keeps
  the single-file exe small (the Unity Ambient.wav was 34 MB → 3.3 MB OGG).
- **Entry files:** `native.zig` / `web.zig` call `backend.initAudio(settings)`
  after `createSessionSetup` + `fixupPointers` (settings must be loaded).
  Web autoplay policy: browsers may block audio until a user gesture; the
  stream simply won't play until then, never crashing.

## Animation

Sprite animations are a **rendering** concern, never a gameplay one. They are
purely a function of wall-clock time and live in `view()`; the renderer stays
dumb (draw sprite + source rect). Two classes, with different state homes:

- **Looping anims** (the flag banner): `frame = (animation_clock /
  frame_duration) % frame_count`, computed in `view()`. No per-instance state.
  The flag banner (`world/flag.png`, 8 frames of 256×512, same pivot as the
  pole) is drawn over `world/flag_pole` at the same screen position via
  `LevelEndDrawable.banner_source_rectangle`. Used for both level-end and hub
  mission-start markers. On the LEVEL screen the banner is the
  completability signal: it renders only while `Level.hasActiveEnemies` is
  false - the SAME rule the win condition checks, so the waving banner
  means "stepping on the exit would end the level" and the bare pole means
  "enemies remain". Hub mission-start and editor markers always wave (not
  levels - no enemies).
- **One-shot anims** (attack swings, hit flashes, death dissolves): the
  trigger lives in **event handlers** - exactly where one-shot sounds live
  (see Audio). A handler calls `session.queueAnim(allocator, PendingAnim{
  event_index, kind, duration_us })` gated `!history.replaying`, right next
  to its `queueSound` call. `frame()` drains `session.pending_anims` after
  the update drain (alongside `drainPendingSounds`), stamps `end_clock =
  animation_clock + duration_us` from the LIVE clock, and appends to
  `session.active_anims`. `view()` shows anims whose `event_index <
  current_event_index` (the triggering event is in the projected history -
  same exclusive bound the combat log uses, so undo hides it) AND
  `animation_clock < end_clock` (not yet elapsed). Undo lowers
  `current_event_index` → the undone anim vanishes (gated out, not removed).
  Redo raises it → a stale anim's `end_clock` is in the past → not re-shown.
  A screen/world transition clears `active_anims` + `pending_anims` (an anim
  belongs to the world it was triggered in; a level-to-level or
  hub-to-level change invalidates it) via `session.clearAnims()`, in the same
  live-loop reset block that clears `ui_state`/`tile_cursor`/`camera_pan`.
  Later-pushed anims append later → draw later → stack on top (the most
  recent skill use reads on top). No explicit removal of elapsed entries;
  `active_anims` grows unbounded within a screen (accepted, same tradeoff as
  `event_history`) and is bounded in practice by short durations + the
  transition clear.
  Three landed cases (all single-frame, no sheet):
  - **Skill-icon pop** (500ms): `skill_icon` kind, shows the skill's icon
    above the caster's actual art top (the `top` edge of the sprite's
    opaque-pixel bbox, via `RenderContext.sprite_bounds`), offset above the
    always-on health bar, tinted with the caster's team gradient index 1
    (player → player gradient, enemy → enemy gradient - same convention as
    weapon colors).
  - **Hit flash** (250ms): `hit_flash` kind, shows the `world/hit_flash`
    sprite (256×256, ported from the Unity project's 512×512 Hit.png at
    0.5x) centered on the defender's rendered art - horizontal frame center
    (entities are always horizontally centered) + vertical center of the
    opaque art bbox (midpoint of the `top` and `bottom` edges from
    `sprite_bounds`). Tinted with the active theme's `lightest` color (the
    artist's offwhite). Triggered by the `damage` apply arm (attack- and
    collision-sourced hits converge there - see Architecture → Damage apply
    split)
    **only when the defender takes nonzero damage** (a Reflect-zeroed or
    0-damage hit does not flash - the damage number still shows a "0"),
    inside the `if (incoming_damage > 0)` block right after the health
    subtraction; a killing blow still flashes
    (`death` zeroes health but leaves the slot). `sprite_bounds` is
    populated per-frame in `frame()` (one decode per sprite via
    `ensureSpriteBoundsLoaded`, caching the full bbox).
  - **Damage number** (500ms): `damage_number` kind, floats the incoming
    damage value away from the defender's sprite in the normalized
    attacker→defender direction (one of 8; self-damage where the delta is
    `(0,0)` falls back to top-right `{1,-1}`, same as heals), starting from
    the bbox edge/corner nearest that direction and traveling half a tile, eased with
    `tween.easeOutCubic` (fast then slow). The number tracks the entity
    (resolved from the live level each frame, like the skill icon). Tinted
    with `active_theme.lightest` + a black edge-outline via the SDF
    text-outline pipeline (see below). Triggered
    by the `damage` apply arm
    (same convergence); unlike the hit flash it shows even on a 0-damage hit (a
    fully-absorbed collision/attack renders a "0") so a connecting hit is
    observable - only the hit flash is gated on `incoming_damage > 0`.
  - **Heal number** (500ms): `heal_number` kind, floats `+value` up-right
    from the entity's top-left bbox corner (heals have no attacker, so the
    direction is fixed), same easing + outline + tint. Triggered by the
    `heal` handler only when heal is actually applied (a full-health heal
    shows nothing).
  - **Aggro indicator** (500ms): `aggro_indicator` kind, shows the
    `world/aggro` sprite (128×128, ported from the Unity project's
    EnemyAggro.png) above the entity's health bar (same placement as the
    skill-icon pop), tinted with the active theme's `lightest`. Triggered
    by the `aggro_check` handler when an entity's `is_active` flips true
    (gated `!replaying`) - once per entity per level (the handler skips
    already-active entities). Skip dead entities at render time. See
    DESIGN → Animation.
  - **Per-entity stagger:** number anims share a `last_number_start_by_entity`
    map on `SessionState`; `frame()` stamps `start_clock =
    max(animation_clock, last_for_entity + 125ms)` so a same-entity multi-hit
    in one drain (e.g. Bash's attack+collision) spaces its numbers 0.125s
    apart instead of overlapping. `ActiveAnim.start_clock` holds the start;
    `view()` gates by `animation_clock >= start_clock` (invisible before
    start) AND `< end_clock`. Non-number anims get `start_clock = end_clock -
    duration` (start immediately). The stagger map clears on screen/world
    transition alongside the anim lists.
  - **Tweening:** `src/tween.zig` holds pure easing fns (`easeOutCubic`);
    `view()` computes `progress = (clock - start) / duration` clamped to
    [0, 1], eases it, and interpolates position. Pure, rendering-side,
    replay-safe.

### The replay-purity invariant (why the clock is read in `frame()`, not handlers)

**Event handlers must not read `animation_clock` (or any wall-clock time).**
`verifyReplayMatch` (state.zig) compares *events* - the stack-top event about
  to dispatch vs. `event_history[current_event_index]` - via `deepEqual`. It
does NOT compare GameState fields after a handler runs. So a handler that
read the clock and wrote `entity.swing_end = clock + duration` into GameState
would be **impure** (its output would depend on wall-clock time, not just
`(state, event)`), and the divergent field would land silently in
`current_state` during replay - invisible nondeterminism, worse than a panic.
Also, the clock is on `SessionState` (off the snapshot timeline), so during
replay it holds the undo-time value, not the original-fire-time value → the
anim would re-play on undo (the behavior we explicitly don't want) and be
nondeterministic. The one-shot design keeps handlers pure by splitting the
trigger from the clock read: the handler pushes a `PendingAnim` carrying
only `{event_index, kind, duration_us}` (a pure side effect gated
`!replaying`, same shape as `queueSound` - it touches `SessionState`, never
`GameState`), and `frame()` is the ONE place that reads the live
`animation_clock` to stamp `end_clock`. So handlers never touch wall-clock,
the invariant stays a bright line, and the `!replaying` gate at the push
site is what prevents re-fire on undo/redo (replay queues nothing). This
mirrors Audio exactly: `queueSound` pushes a side effect gated `!replaying`;
`queueAnim` does the same with a richer payload. The only anim-specific
machinery is the `end_clock` stamp (the irreducible cost of being temporal -
a sound is done at push, an anim has to stay visible for a duration and
react to timeline scrubbing) and the `view()` event-index/time gating.

### The animation clock

`SessionState.animation_clock: u64` - accumulated session-relative
microseconds, off the undoable GameState → never in snapshots → replay-safe by
construction (replay doesn't render anyway). Advanced by `frame()` **pause-
gated** alongside the wait timer: when the world is paused (options menu /
pending error open), the clock freezes too, so anims freeze in place and
resume cleanly; when waits drain, anims advance. A fresh session starts at 0
so looping anims begin at frame 0 (raw wall-clock mod would start mid-loop).
One-shots store `end_clock = animation_clock + duration` in session-relative
units, so pause freezing also freezes one-shots mid-flight. The outline
stripe shader's phase (`ViewState.outline_stripe_phase`) is another
looping consumer, but stepped off the UNGATED `session_clock` instead -
outlines are UI + decorative, so they march everywhere, pause included
(Platform Seam → Outline stripe shader).

### Frame rate

`settings.animation_fps: u32 = 8` (Display section of `data/default_settings.txt`) is
the ONE global rate all anims share; frame duration = `1_000_000 /
animation_fps` microseconds. `view()` reads it (for the flag now; for one-shot
gating later). A future anim needing a different rate becomes a per-anim
override (deferred). A `0` fps is treated as the default (8) to avoid
divide-by-zero. It's a display/pacing preference (like `camera_zoom`), not
gameplay - not in snapshots, not touched by replay.

## Replay & Side Effects

- Undo/redo reconstruct past states by replaying the event history through
  `processEvent` (see `GameStateHistory.replayTo`). `history.replaying` is true
  during this.
- Event handlers must run **pure state transforms unconditionally**, but gate
  **observable side effects** (file writes/downloads, audio, dialogs) on
  `if (history.replaying) return;` so scrubbing history doesn't re-fire them.
- **Reconstruction reads** (level/hub/save config loads in start_level/
  start_hub/load_save) still run during replay - the rebuilt state depends on
  their contents. On web these are asset fetches, not user dialogs.
- The `wait` event already satisfies this by construction (it lives in
  `update()`, which replay bypasses).
- **All undoable gameplay state is mutated only inside event handlers.** Replay
  rebuilds state by re-running events, so a direct write in the input/update
  path (`handleIdleInput`, `handleAnytimeInput`, `gameLoop`) is NOT reproduced
  and the reconstructed state silently diverges. To change gameplay state, push
  and handle an event (e.g. `clear_highlights`, `clear_prepared_skill`, and
  `turn_end` owning `turn_phase = null`). Helpers like `refreshMoveHighlights` /
  `cancelPreparedSkill` write directly ONLY because they are called exclusively
  from event handlers, so they already run during replay.
- **Transient view/input state lives off the undoable GameState.**
  `state.SessionState` (`input_state`, `ui_state`, `tile_cursor`) hangs on
  `GameStateHistory` next to `settings` - never deep-copied into snapshots,
  never touched by replay. Clean rule: **in `GameState` → change via events; in
  `SessionState` → change directly in the input/update path.** The line is
  the UI state classification (see UI Framework → UI state classification):
  class-1 SEMANTIC SURFACE state (what's open - panels, modals, pickers)
  lives on `GameState.ui_surfaces` behind `toggle_ui_surface`-family events,
  because replay must reproduce it and `validatePlayerAction` must gate
  gameplay orchestrators on it; classes 2-4 (tabs, scrolls, gesture
  lifecycles) stay here. The screen/world-change reset splits by the same
  rule: surface closing is handler work (`transitionScreen` /
  `start_level` / `start_hub`), while the classes-2-4 wholesale reset lives
  in the live loop (`gameLoop` clears `session.ui_state` when `screen` or
  `world_generation` changes across `update()`, covering both event
  transitions and undo/redo across a boundary), NOT in `transitionScreen`. `input_state` is never reset - it is live hardware
  state. `tile_cursor` is the logical cursor (mouse or arrow-key driven);
  `auto_target_at_cursor` reads it in the input path, and the resulting
  `player_use_skill` event is what replay reproduces - the cursor value at
  prepare-time is never needed for reconstruction, so it's safe off GameState.
  Resolved per-frame in `update()` (`resolveTileCursor`): mouse-move drives it
  (with UI occlusion + tile validity), arrow keys nudge when the mouse is idle
  (snapping to the player tile if null). A nudge onto empty space CROSSES THE
  GAP: the cursor jumps to the first tile on the ray in the nudge direction
  (`nearestTileAlongDirection` - diagonals follow the combined diagonal ray;
  no tile in that direction → the cursor stays). The editor cursor always
  moves one step with no tile-membership clamp - acting over empty space is
  the point there. Re-activating the slot of an
  already-prepared skill toggles the preparation OFF (`resolveSkillSlotAction`
  → `player_cancel_skill`); the auto-target hit still takes precedence and
  fires - a same-slot press never resolves to a recorded no-op.
- **Replay must not create events; new actions branch the timeline.**
  `processEvent` records into `event_history` only when `!replaying` (via
  `GameStateHistory.recordEvent`); the event index still advances (processEvent
  increments it before dispatch) so `replayTo`'s loop progresses, and each
  stack-top event is verified against the recording (`verifyReplayMatch`) -
  replay is strict-validation, not just rebuild. See Determinism & Tiebreaking →
  Replay VERIFICATION for the natural-stack machinery. Taking a new action
  after an undo discards the stale future first (`discardFutureTimeline`:
  trims `event_history` + `idle_points`, frees snapshots/checkpoints ahead of
  the branch), so the new action continues a fresh timeline from the undone
  position.
- **Undo mid-drain reverts to the current idle point.** Idle points (undo
  stops) are recorded only when the event stack EMPTIES - a player action's
  full subtree completing. So during a drain (e.g. enemy turns with waits
  after the player ended their turn), `current_idle_index` still points at
  the idle point BEFORE the drain started - the state the player was just
  at. `undo()` detects mid-drain (stack non-empty OR wait active) and
  reverts TO that current idle point (cancelling the partial drain via
  `discardFutureTimeline`) rather than decrementing past it (which would
  land one idle point further back than expected). The partial drain's
  recorded events are discarded - the action never completed, so there's
  nothing to redo. A second undo (now idle) decrements normally.

## Versioning

- `game_version` is the runtime "which build" stamp: `YYYY.MM.<commits-this-
  month>[-dirty]`, computed in `build.zig` (`computeGameVersion`) from the
  build clock + git and exposed to code via `@import("build_info").game_version`
  (a `b.addOptions` module wired onto BOTH the exe and test root modules).
  Git is optional/build-time-only (never a runtime dependency - the string is
  baked in): git ran → real count (a true `.0` is legitimate) plus `-dirty` on
  a modified tree; git absent/no repo → `YYYY.MM.unofficial`.
- `game_version` is ADVISORY: recorded into artifacts and warn-on-mismatch, not
  a hard gate (a hard replay-validity guarantee would need content-hashing the
  gameplay logic - future work). It is NOT `build.zig.zon` `.version`, which
  stays a static, vestigial package-identity `0.0.0`.
- Two orthogonal versions, both recorded in serialized artifacts:
  `file_format_version` (monotonic int per artifact, in its `Metadata` section)
  answers "can this parser read the file?"; `game_version` answers "will a
  correctly-parsed file behave in this build?".
- `file_format_version` is on the config file types that carry a `Metadata`
  section today (levels, hubs, missions, campaigns, player saves, settings,
  color themes, player loadouts, decorations) - one monotonic int per type,
  in the file's `Metadata` section (the FIRST section, before any type-
  specific sections). Weapon-type definitions and salvage tables are config
  files WITHOUT a version (no `Metadata` section); they'd join if their
  format stabilizes. The loader validates it as a HARD gate over a
  supported RANGE (`oldest_supported_*_file_format_version`..
  `<type>_file_format_version`): a missing/unparsable version, one older
  than the floor, or one newer than this build all return
  `error.UnsupportedFileFormatVersion`. Most types have no older supported
  version (floor == current, exact match); the Layout-bearing types are
  ranged - levels 1-2, hubs 2-3 - because the older versions select the
  legacy Layout grammar (DESIGN → File System & IO → Config grammar).
  The validated version is RETURNED to the caller for version-paired
  strictness (a current-version level/hub with a bare Layout errors) and
  is not stored on the parsed type - it's a parse-time compatibility
  check, not runtime state. The save writer emits the current constant in
  a `Metadata` section. Per-type version constants live in parser.zig
  (`level_file_format_version`, `hub_file_format_version`, etc.).

## Logging & Replay

### Spawn-relative coordinates (the parse-time normalization)

`loadLevel` / `loadHub` displace EVERYTHING in a loaded layout by
`-player_start` after the layout walk, so the player spawn (`!`) is always
world (0,0) and coordinates can go negative. Rationale: the raw layout grid
assigns world position = grid index, so growing the layout bbox left/up
(adding a decoration off the playable area) shifted every existing thing -
and absolute positions in recorded logs (validation replays, session logs,
crash dumps) silently broke. Spawn-relative positions are invariant under
bbox growth in ANY direction. The editor load path (`buildEditorMission` →
`loadLevel`) shares the normalization, and the editor's writer already
offsets by bbox origin, so load→save round trips are idempotent; the file
bytes are untouched, so content hashes of existing missions are unaffected.
Levels/hubs without a `!` are left as-is (nothing to anchor on).

(session-log read/write/reconstruct is built; combat-log projection is built;
combat-log UI rendering + replay-viewer UI still TODO)

- There is ONE log: `event_history` (see Replay & Side Effects). The session
  dump, the combat log, and the future replay viewer are all it plus
  projections - not separate capture systems.
- Session dump (ctrl+L → `dump_event_log` → `input_handlers.dumpEventLog`):
  serialize `event_history` to config format via
  `session_log.writeEventLog` - a comptime-generic serializer over the
  `Event` union (lives in session_log.zig; new events need no changes).
  `Metadata` header carries file_format_version + game_version + created
  timestamp; an `EventLog` section holds one entry group per event
  (`event <category> <variant>` discriminator + one line per payload field;
  optionals omit their line when null; Vector2/Materials/slices
  space-separated). Events alone reproduce a session - do NOT also log
  player input (the input→event translation is deterministic and would be
  redundant/divergent). The dump lands as a session-log BUNDLE (see the
  Session-log bundle subsection below) - events alone reproduce the state
  TRANSITIONS, but the bundle's embedded content is what makes the
  reconstruction reads reproduce.
- **String safety (the encoding rule):** a NESTED string (inside a struct or
  union payload field) can't contain spaces - nested values serialize as
  one space-separated token stream, and a string's spaces would break the
  reader's positional regrouping. Two mechanisms keep every string
  spaces-safe: single nested values FLATTEN to top-level event fields
  (`editor_set_entity_gear`, `editor_set_item_def`, the layer events -
  a top-level string line is verbatim), and a slice of structs carrying
  strings (`editor_set_decoration_def`'s `layers`) takes the INDEXED
  multi-line encoding - `<name>_count N` + `<name>_<i>_<field>` lines,
  each string on its own line (`writeIndexedSliceField` /
  `parseIndexedSliceField` in session_log.zig, comptime-detected via
  `isStringBearingStructSlice`; `appendEventScalar` compile-errors if a
  string-bearing slice ever reaches the one-line path). This is what lets
  mission directories / custom asset stems carry spaces
  (`custom/My Mission/canopy`).
- Reader: `session_log.loadEventLog(sections)` → `SessionLog {
  file_format_version, game_version, created, events }`, the
  comptime-generic inverse. file_format_version is a HARD gate; game_version
  is advisory (caller warns via `input_handlers.warnIfSessionLogFromDifferentBuild`).
- Reload does NOT re-drive events through the input path. `event_history` is the
  fully-linearized event stream; `GameStateHistory.reconstructFromEventLog`
  deep-copies the loaded events into `history_arena` and drives the existing
  `replayTo`/`restoreTo` machinery (which forces each recorded event onto the
  stack in turn, discarding handler-pushed sub-events since those were
  themselves recorded - but VERIFIES them first via `verifyReplayStep`, see
  Determinism & Tiebreaking; verification runs even cross-session now). `idle_points` are NOT serialized - step
  boundaries are derived, not stored. The `runToIdle` +
  `reconstructFromEventLog` end-to-end test (main.zig) proves forward play ==
  replay.
- Combat log = a filtered PROJECTION of `event_history` (derived on demand,
  NOT stored on GameState - the old `CombatLogEntry`-on-`Level` scaffolding is
  DELETED). The replay viewer steps over the SAME filter, so one whitelist
  drives both the combat-log UI and replay stepping. The tier split is DECIDED:
  coarse (one entry per move / skill use / death) + fine (each consequence:
  attack / stun / knockback / retreat / heal / create_effect / end_effect /
  collision / pickup_items) + none (the rest). `combat_log.zig` exposes
  `projectCombatLog` + `combatLogTier`; `view()` projects per-frame into the
  frame arena and `ViewState.combat_log` carries the `[]const Event` slice
  (scoped to the current level, up to `current_event_index`, so undo truncates
  the future and the hub shows no log). Remaining work is RENDERING (top-bar
  coarse recent-icons view + full-screen detailed log) and replay-viewer
  stepping.

### Session-log bundle (the cross-session artifact)

A saved session must replay against the exact bytes it originally read -
later file changes (the autosave overwritten by every subsequent session,
custom missions re-saved by the editor, mod-shadowing of shipped content)
must not diverge a replay. The BUNDLE is the folder artifact that makes
that true (`src/session_log_bundle.zig`):

- Layout: `<bundle>/session_log.txt` (the ordinary session-log body plus a
  `ReconstructionCache` manifest section - one entry group per cached read:
  `event_index`, `path` (verbatim, spaces allowed), `hash` (SHA-256 hex of the
  bytes), `file`) + `<bundle>/content/<first 8 hex>_<original file name>` -
  EXACT raw byte copies, openable as-is.
- EVERY cached read is embedded, shipped content included (mod-shadowing
  means any path can change between sessions). Deduped by hash: identical
  bytes stored once; distinct bytes of the SAME path (the autosave written
  mid-session, then re-loaded) hash differently → distinct copies.
- Writer (`writeSessionLogBundle`): content files FIRST, session_log.txt
  LAST - a half-written bundle fails to load cleanly instead of replaying
  against missing bytes. Consumers: the ctrl+L dev dump
  (`logs/session_<timestamp>/`), the crash dump
  (`crashes/crash_<timestamp>/` - the crash report carries the embedded
  content, so it is exactly reproducible on any machine).
- Loader (`loadSessionLogBundle`): the manifest section is REQUIRED (a
  bare session log - e.g. the validation replay - is not a bundle); every
  content copy is verified against its recorded hash; a missing or tampered
  copy is an error, never a silent fallback to some other file on disk. A
  non-monotonic `event_index` (a hand-merged manifest) rejects - the
  replay-side binary search depends on cache order. Reads are bounded
  twice: per copy (256 MB, matching FileSource's read limit) and in the
  AGGREGATE (1 GB over all content copies, checked on each copy's size
  BEFORE it is read - a hostile many-distinct-copies bundle fails without
  allocating a byte of content; a hardening must for the future
  server-side bundle consumer).
- Replay path: `GameStateHistory.loadReconstructionCache` pre-populates
  the cache from the manifest (order preserved), then
  `reconstructFromEventLog(.authoritative)` - a cache miss is a broken or
  hand-edited bundle and panics; the files on disk are never consulted.
  (`--replay` CLI: `main.loadAndReconstructSession`.)
- The validation replay deliberately does NOT use bundles: it stays a
  single file inside the mission dir it validates and replays against the
  mission's CURRENT files (hash-gated upstream) via
  `reconstructFromEventLogChecking` - the `.lazy_disk` read policy, the
  ONLY user of the disk fallback in `readReconstructionFile`.
- file_format_version 2 (no compat - pre-release, no playerbase): v1 logs
  and v1 validation replays are unreadable; re-record.
- Custom ASSETS (sprites/audio) are deliberately NOT embedded - only the
  config bytes the reconstruction reads. Sprite identity travels as stems +
  dims in events and level files (dims resolve at the pick-commit input
  path, never in a handler), so state replay is byte-exact with zero PNG
  bytes involved. At render time the texture cache loads whatever art is
  on disk NOW (missing → magenta gate) - the replay is state-exact, art is
  presentational. Embedding referenced PNGs was considered and rejected:
  it would multiply the bundle's size for viewer fidelity only.

## Determinism & Tiebreaking

- Replay no longer papers over nondeterminism: the natural-stack replay
  loops (`replayTo` / `replayToWithIdleTracking`) let `processEvent`'s
  pop/push machinery run and verify each stack-top event against the
  recording (see Replay VERIFICATION below). A handler that pushes a
  different child than the original session did now panics instead of the
  state silently staying correct via force-fed recorded events. The old
  "replay is robust to nondeterminism" property is deliberately replaced by
  strict validation - the whole point. Determinism still matters for live
  behavior regardless, so make ordering explicit.
- **Replay VERIFICATION.** The replay loops (`replayTo` /
  `replayToWithIdleTracking`; `restoreTo`'s slow path delegates to
  `replayTo`) use the **natural stack** to drive replay + verification.
  Instead of force-feeding each recorded event and discarding handler
  outputs (the old model), `processEvent`'s pop/push machinery runs
  naturally: before each dispatch, the stack top is the event that should
  run next, and `verifyReplayMatch` confirms it equals
  `history[current_event_index]`. Handler-pushed children interleave with
  their own subtrees in the recorded stream, and the stack tracks that
  interleaving for free (it IS the DFS cursor). When the stack drains, the
  next recorded event is a fresh top-level player action - the loop seeds
  it (top-level events come from player input, not handlers, so the
  recording is authoritative there and the check is trivial). Comparison is
  `deep_copy.deepEqual` (comptime-generic, mirrors `deepCopy`; no floats in
  event payloads → exact `==`). A mismatch is a fail-fast `@panic` naming
  the recorded index, both variant tags, and the first differing payload
  field (`deep_copy.firstDiffField` recurses through the union payload
  struct). Runs for ALL replay origins including cross-session
  (`reconstructFromEventLog`) - a divergence is a nondeterminism bug we want
  surfaced, not silently rebuilt state. (Cross-session replay runs from a
  session-log BUNDLE with the content embedded - the exact bytes the
  original session read - so a divergence is a genuine bug, not a changed
  file; see Logging & Replay → Session-log bundle. The revalidate path
  replays against the mission's current files BY DESIGN, hash-gated - a
  mismatch there is a benign answer via checking mode, below.)
  **Semantic shift:** replay is now
  strict-verification, not robust-rebuild - a nondeterministic handler
  panics instead of the state silently staying correct via the recording.
  This is the point of validation. Idle-point derivation in
  `replayToWithIdleTracking` simplified: the real `event_stack.len` replaces
  the old virtual-depth bookkeeping (idle = stack empties). This is also the
  primitive the Online Services TODO wants for server-side replay validation
  (leaderboard anti-cheat).
- **Replay CHECKING mode (the revalidate seam).** All three verification
  layers route through `GameStateHistory.rejectReplay`: normal mode
  (`replay_checking = false`, every standard replay origin) fails fast via
  `@panic` exactly as before; checking mode (`reconstructFromEventLogChecking`)
  records the FIRST failure on `replay_rejection` (event index + the same
  message the panic carries) and the replay loop aborts - no crash. Same
  verification logic, two policies: for replay-as-integrity-check a
  divergence is a bug (panic); for revalidate ("does this stored run still
  match the current content?") the same divergence is a benign answer.
  On a rejection the scratch history is left mid-replay and discarded.
  This is the in-process miniature of the future server-side mission
  validation (the upload gate) - the same error-returning path, no
  fail-fast wrapper.
- **Replay PLAYER-ACTION LEGALITY validation.** Two layers gate what a
  replay log can seed at an idle point (when the stack drains and the next
  recorded event is pushed as a fresh top-level event):

  1. **Structural whitelist (`isPlayerAction`)** - the OUTER gate. A fail-
  closed `switch` that returns true only for event variants a player can
  push at an idle point, `else => false` for everything else. This closes the
  spoof gap where a hand-crafted log seeds handler-internal machinery
  (`attack`, `turn_end`, `end_level`, `start_mission`, ...) at an idle point.
  The whitelist is a pure tag-check (no continuation inspection) thanks to the
  orchestrator convention (below): every user action maps to a single
  orchestrator event, and machinery events are never whitelisted.
  `player_skip_level` is additionally gated on `build_info.dev_mode`
  (dev-only build).

  2. **Context legality (`validatePlayerAction`)** - the INNER gate. Rejects
  player actions that were illegal at the recorded point: `player_move_action`
  (destination must be in `reachableTiles(...)` - full BFS, matches live);
  hub `move_player` (destination must be a walkable hub tile no NPC
  occupies - `isHubMoveLegal`, the mirror of the live hub click gate; hub
  movement is free-form, so tile-membership + NPC-occupancy is the whole
  rule, no adjacency/BFS - and a move outside a hub rejects: nothing live
  produces it); `player_use_skill` / `player_skip_move_to_skill` /
  `player_prepare_skill`
  (skill on bar + off cooldown + valid target); and the meta exit/skip
  orchestrators (screen must match - e.g. `player_restart_mission` only legal
  at `.level`, `player_exit_to_menu` at `.level`/`.hub`, `player_replay_mission`
  requires `last_completed_mission != null`). The inventory/gear/skills
  click + drag orchestrators additionally require their trigger panel OPEN
  (`ui_surfaces`) - the live pointer path can't click an unrendered slot, and
  the validator mirrors that gate (a salvaged item in a log whose inventory
  was never opened is an illegal log - hand-crafted or otherwise). Surface
  toggles themselves are scope-checked (a middle-panel toggle outside
  level/hub is illegal).

  **Orchestrator convention.** Input handlers push orchestrator events;
  orchestrator handlers push machinery events as children. The whitelist =
  orchestrator events. This 1:1 mapping of user action → orchestrator event
  is what makes the whitelist a pure tag-check. The exit/skip paths used to
  push machinery directly (`end_level{continuation}`, `end_hub`,
  `open_main_menu`, `start_mission`) - those are now machinery-only (handler-
  pushed, never whitelisted, never seeded at an idle point), wrapped by
  `player_skip_level` / `player_restart_mission` / `player_exit_mission` /
  `player_exit_to_menu` / `player_replay_mission` orchestrators. New player-
  pushable events → new orchestrator → add to `isPlayerAction`.

  Both gates run in `replayTo` / `replayToWithIdleTracking` right BEFORE
  seeding a top-level event. Handler-pushed children never reach here (they're
  never seeded - their legality is enforced by the parent handler's own logic
  + `verifyReplayMatch` structurally). Fail-fast `@panic` for now (malicious
  replay = reject); a future viewer-facing load may soften this to the error
  popup, while server-side leaderboard validation keeps it hard. The legality
  LOGIC lives in bool-returning helpers (`isPlayerAction`, `isPlayerMoveLegal`,
  `isHubMoveLegal`,
  `skillOnBarAndOffCooldown`, `skillTargetLegal`) so it's testable without
  panic-catching infrastructure (Zig has no `expectPanics`); the
  `validate*` wrappers are a thin panic-policy layer over them. This is the
  other primitive the Online Services TODO wants for server-side replay
  validation.
- Tiebreaking convention - every ordering/selection over equal keys must break
  ties EXPLICITLY (in the comparator) or by a documented scan order:
  - Entities: ascending `entity_index`.
  - Tiles: ascending `(x, y)` (A* `comparePathNodes` ends with this tier).
  - Skills: slot order.
  - **A* f-cost ties** (`functions.comparePathNodes`): squared euclidean
    distance to the destination first, then the `(x, y)` tile order - with
    the exact Chebyshev heuristic f-ties are common, and the euclidean tier
    resolves them to the really-closer node (a same-row chase walks the
    row; a 45° chase walks the diagonal). The heuristic itself is Chebyshev
    (`chebyshevHeuristic`) - the EXACT remaining cost on open ground, so
    it never overestimates; the old Manhattan heuristic overestimated
    whenever the destination sat diagonally from a node and could pop the
    goal via a longer route before the optimal route's nodes were ever
    expanded (reproduced by fuzzing against a reference BFS - pinned by
    the admissibility test in functions.zig).
  - **AI movement destination ties** (`functions.straighterTileBefore`):
    when the primary metric (cluster score / Chebyshev distance) ties, the
    STRAIGHTER line to the mover's nearest hostile wins - first by
    perpendicular offset from the mover→hostile line (a same-row chase
    stays on its row; a 45° chase walks the diagonal), then squared
    euclidean distance to the hostile, then the `(x, y)` tile convention.
    The old `(x, y)`-only tiebreak habitually stepped a row up on same-row
    chases (the observed bug - a cluster-seeker scoring the row tile and
    the row-above tile equally always picked the lower `y`). Applies at
    all three movement-selection sites: both `ai_movement` destinations
    and the approach-mode reachable-tile fallback (level.zig).
  - **AoE multi-target execution: the spiral** (`skill_helpers.spiralTilesInRadius`,
    walked by `hostileIndicesInRadius` - the one enumeration every radius AoE
    uses). Targets enumerate by TILE, not entity scan order: the innermost
    ring (Chebyshev 1) first, starting at the ring's top-left tile, walking
    CLOCKWISE (top edge left→right, right edge top→bottom, bottom edge
    right→left, left edge bottom→top), then each next ring the same way -
    the impact visibly ripples outward. The CENTER tile is not part of the
    spiral (self-centered AoEs exclude it anyway - the caster stands there;
    meteor is the one exception and strikes the center FIRST, before the
    spiral). Ring n has exactly 8n tiles; one entity per tile makes the
    tile→entity mapping unique. Multi-effect AoE skills group per target
    (all of a target's events before the next target - shockwave's attack +
    knockback, slam's knockback + stun, blitz's attack + stun), so with the
    pacing waits the presentation is one target at a time.
- `std.mem.sort` is UNSTABLE: a distance/priority-only comparator leaves equal
  elements in an arbitrary order - always add the secondary key (e.g. `turn_end`
  enemy ordering breaks distance ties by `entity_index`). A strict `<`/`>`
  accumulation loop that iterates in the convention's order already yields the
  right tiebreak (lowest entity_index / first slot); document it with a comment
  rather than restructuring.
- **AI skill target selection - focus-fire.** Every hostile-targeting
  single-target offensive skill's AI OPTIONS pick the hostile with the
  LOWEST current health; ties break by Chebyshev distance to the caster,
  then `entity_index` (total order). Implemented once in
  `skill_helpers.zig` (`weakestTarget`) and reused by every attack skill;
  two skills get a preference key IN FRONT of the same tail: knockback
  skills prefer a target the push will collide (`knockbackTarget`), stun
  skills prefer an unstunned target (`stunTarget` - see Architecture, the
  stun rule). `nearestTarget` remains only for the non-attack exceptions
  (Swap - swapping with the nearest enemy is the sensible tactical read).
  Rationale: focus-fire kills wounded enemies sooner than spreading
  damage. (Barely observable with today's single-player hostile sets -
  enemy casters usually see only the player - but it is the convention
  new skills follow and matters once multi-entity teams exist.)

## Input

- **Binding contexts are DERIVED from the action - a key combo may be
  bound once per context.** There is NO per-binding context: a binding's
  active contexts ARE `actionBindingContexts(action)` - the single,
  compiler-enforced declaration (see the next bullet). `frame()` computes
  the frame's active `BindingContextSet` and hands it to `translateInput`;
  `bindingFires`/`isActionHeld`/`isSuppressed` skip a binding unless its
  action's contexts intersect the active set (an inactive binding is not a
  precedence competitor either). Bindings on actions in DIFFERENT contexts
  may share the same combo (Digit1 = skill 1 in game, select tool in editor)
  and never co-fire. The settings file still carries a per-binding
  `context` line - INFORMATIONAL: the writer emits
  `primaryBindingContext(action)` (first declared member of the action's
  set), the loader IGNORES the line entirely (context-less entries parse
  fine); the line exists so an older binary (which requires + validates it)
  keeps working and the file stays human-readable. The active set: while
  `pending_error` is set, ONLY `error_popup` is active - the popup is modal,
  even `anytime` is swallowed (this makes the old ArrowUp dual-bind explicit:
  with the popup up only `error_scroll_*` fires, without it only
  `move_cursor_*`; the handler-side pending_error gate remains as the
  wheel-redirect + defense-in-depth). Otherwise the screen picks its
  context and `anytime` rides along (level/hub → game, editor → editor,
  campaign_editor → campaign_editor - the TWO EDITORS have SEPARATE
  contexts, so the same combo can bind once per editor (ctrl+S is
  save_editor_mission on the mission editor, save_campaign on the
  campaign editor; Digit1 is the mission palette's select tool there, the
  campaign map's here) without shadowing - the derived gate keeps each
  dormant on the other's screen; main_menu → menu, replay_viewer → none
  yet). An editor
  playtest/validation run is a `.level` screen, so the game set activates
  and the editor set goes dormant - the run plays like gameplay with zero
  special cases (`save_editor_mission` is editor-only so ctrl+S is dead
  mid-run; `save_game` is game-context and additionally handler-gated
  against editor runs - the run's player_data is throwaway, same reasoning
  as the view hiding Export Save mid-run). The editor-browser family
  (toggle_editor_browser, tabs, rows, import, new mission, new campaign)
  fires on BOTH editor screens (editor + campaign_editor contexts): the
  browser still OPENS from the main menu via its buttons
  (clicks bypass the context gate; the consumption sites keep their
  `editorBrowserReachableScreen` gate for those), but a main-menu surface
  has no editor semantics for the shortcuts. Button clicks bypass the gate
  entirely (`applyAction` sets actions directly) - buttons only render in
  their context.
- **Action↔context classification is declared + compiler-enforced.**
  `types.actionBindingContexts` is an exhaustive no-else switch classifying
  every Action into its firing contexts - the single declaration of "where
  does this action fire", and a compile error to add an Action without
  classifying it. With derived contexts this switch IS the binding gate -
  there is no load-time validity layer anymore (nothing to validate: no
  binding can name a context its action doesn't fire in). What `loadSettings`
  still validates per entry: the `action` itself (unknown → warn + drop).
  `settings_file_format_version` did NOT bump: old files parse (context
  lines ignored, scalars untouched) rather than being rejected wholesale.
- **New keybind wiring sites (three, easily forgotten).** A new keybind
  touches: (1) the binding entry in `data/default_settings.txt` (including
  its informational `context` line), (2) the `Action` enum + its
  `actionBindingContexts` case, (3) the `AnytimeInput`/`IdleInput` field +
  `applyAction` + the consumption site - the action-layer SOUND is automatic
  (the fired-actions choke point covers every non-excluded action; only an
  OUTCOME-gated sound needs a consumption-site queue). The dispatch itself
  is NO LONGER a
  site: the one dispatch pass (see Dispatch convergence below) fires every
  binding automatically - the old per-action `checkAction` line is gone,
  and with it the ctrl+S missing-dispatch-line bug class. The backend's
  key table is NO LONGER a site either: `key_mappings` in
  src/raylib/input_poll.zig maps the FULL W3C id set (every key raylib can
  report), so any binding name reaches `translateInput` with no backend
  edit. Historical instance of a site being forgotten: ctrl+A select-all
  (missing backend entry). The startup warning for bindings naming inputs
  no backend mapping can produce is still TODO (see TODO →
  New-keybind pipeline friction).
- **Dispatch convergence - one pass, one seam.** `translateInput`'s action
  section is ONE pass over the bindings: every binding that passes its
  gates (`bindingFires`: derived-context intersection, required-modifier
  subset, a real press edge or a whitelisted synthetic repeat, not
  suppressed) fires its action through `applyAction` - the ONE
  action→PlayerInput mapping, shared by UI button releases (main.zig),
  fired keybinds, and console `action` commands, so a binding and its
  button land on the exact same fields and EVERY action is uniformly
  keybindable (the keybinds tab's action picker lists the whole enum; the
  derived-context gate keeps each action to its screens - menu commands
  included, which the old per-action dispatch lines never checked, so a
  binding on `new_game` was silently dead until the convergence).
  Iterating the bindings, not the actions, keeps the pass O(bindings) -
  actions with no binding are never touched - and the context gate reads
  a comptime-materialized table (`action_binding_contexts_lut` in
  types.zig, the generated-lookups pattern: the switch stays the single
  source of truth, materialized at comptime because the gate runs once
  per binding and once per competitor inside `isSuppressed`). Same-frame
  degeneracies resolve first-listed-wins (the conflict rule's tiebreak):
  equal-specificity same-combo competitors are suppressed inside the
  pass; the skill-slot guard keeps one slot selection (a same-frame
  double-slot press keeps the first-listed binding's slot). The
  keyboard-only editor shortcuts (Digit1-5 tools/palette groups - no
  button carries them) BRIDGE onto the click paths' options_action +
  payload pairs inside `applyAction` (the payload is the keyboard
  action's own identity), so keybind, click, and console all share the
  consumption sites. The handler arms stay in one file: no dispatcher
  split now - if input_handlers crosses ~7k lines or the hub/campaign
  arms stop fitting one scan, the hub/campaign arms split out alongside
  the editor arms (a real seam, not a chore split).
- **Button payloads - one union, riding the frame.** A clicked button's
  identity BEYOND its action (which row, which tab, which cell) is ONE
  tagged union, `types.ButtonPayload`, riding `PlayerInput.clicked_payload`
  alongside the action `applyAction` folds. Same-frame only: valid in the
  frame it was set, read by the consumption arm that fired its action
  (`payloadAs` in input_handlers.zig: "my arm's variant, or the click
  didn't happen"), dead after. The relay in main.zig is ONE line with a
  fail-fast check against `types.actionButtonPayload` (the
  `actionBindingContexts` pattern: an exhaustive switch, so adding an
  Action is a compile error until its payload story is decided; plus a
  comptime no-orphan walk so a variant no action carries is a compile
  error) - a wrong or missing variant panics at the relay instead of
  being silently eaten by the arm's `orelse return`. Console `action`
  commands carry no payload; a payload-needing action fired that way
  no-ops at the arm by design - the payload IS the click. The payload
  never crosses the input→event seam (handlers translate clicks into
  events), so no event-log or version impact. Compound button identities
  are one struct variant, not two (a weapon-type cell:
  `{ gear_slot, weapon_type }`); null-meaningful identities keep the
  optional INSIDE the variant (`.editor_layer` null = the picker's add
  mode; `.editor_skill` null = the picker's None cell). `SlotRef` stays
  PURELY the drag domains (inventory/gear/skill_bar/learned_skill);
  save rows ride `.save_row`, not the drag union.
- **The PlayerInput placement rule (data rides the frame; behavior rides
  its classification).** Actions classify by when they may consume -
  `AnytimeInput` actions on every `update()` call, `IdleInput` actions
  only when the stack is drained. Inert frame-level data - data that
  never consumes anything by itself - rides `PlayerInput` directly:
  `pointer`, `modifiers`, `text_edit_outcome`, `keybind_capture_outcome`,
  `fired_actions`, `clicked_payload`. Data doesn't classify by when it
  consumes, because it doesn't consume; asking "AnytimeInput or
  IdleInput?" of a payload is a category error (the 28 per-field
  `clicked_*` split that preceded this rule had exactly that blur -
  payloads scattered across both structs by which arm happened to read
  them). Two near-misses the rule flags and explains: `IdleInput`
  .tile_clicked is NOT inert (handleIdleInput mutates it mid-consumption -
  Enter folds the cursor into it - making it the idle path's resolution
  value, not a frame fact); `IdleInput.skill_slot_selected` is not click
  identity - the `.skill_slot_N` action itself encodes it, and `applyAction`
  unpacks the action's own number (the payload channel exists only when
  the action does NOT encode the identity; the Digit bridges differ by
  mapping a DIFFERENT keyboard action onto the click action + payload).
- **macOS: Command reports as the Control ids.** Mac convention is Command
  for app shortcuts, so on macos targets the backend key table maps
  `left_super`/`right_super` to `ControlLeft`/`ControlRight`
  (`mac_key_mappings` in src/raylib/input_poll.zig, comptime-gated): every
  `ControlLeft` binding fires on Cmd, and physical ctrl keys keep working.
  The ids flowing into `translateInput` stay platform-agnostic (one
  binding set ships for all platforms in `data/default_settings.txt`);
  the convention lives at the backend key table, the same site that owns
  physical-key → id mapping.
- **Binding modifier match is subset, not exact.** A binding's modifiers are
  REQUIREMENTS, not an exact match: a plain binding fires regardless of held
  modifiers (so ctrl+key works for any plain-bound action - e.g. ctrl+Space
  skip with `force_attack_step`); a ctrl binding fires only when ctrl is held.
  `bindingFires` skips only when a REQUIRED modifier is NOT held. This matches
  the button-click path (`applyAction` sets the action directly with no
  modifier filtering) so keyboard chords and clicks behave the same.
- **Hybrid precedence - most-specific chord wins within the active
  contexts; a combo conflict is won by the earlier list entry.** When two
  bindings share the same physical input (same key/button id) AND both are
  active (derived contexts intersect the frame's active set), the one whose
  required modifiers are a SUPERSET (in count, all held) wins and suppresses
  the less-specific one: ctrl+Enter beats plain Enter. Equal-specificity
  bindings on the SAME action never suppress each other (both fire the
  same flag - the loader dedupes the combo). Equal-specificity bindings on
  DIFFERENT actions are a CONFLICT - one combo fires one action per
  context - and the EARLIER list entry wins (`isSuppressed`'s
  first-match-wins tiebreak): the deterministic fallback, reachable only
  via a hand-edited file, since `loadSettings` warns + drops conflicts
  (the later entry) and the keybind UI prevents them. Same-combo
  different-context pairs are NOT ties - the context gate resolves them
  upstream (see Binding contexts). `bindingFires` / `isActionHeld` suppress
  a matching binding when another ACTIVE binding on the same input either
  matches the held modifiers with strictly more required modifiers, or
  equals them on a different action from an earlier list position
  (`isSuppressed`, `modifierSpecificity`).
- **Binding conflicts (one combo → one action per context) are validated at
  load.** Same combo (`sameCombo`: same input + same required modifiers) on
  DIFFERENT actions whose derived contexts INTERSECT (they would co-fire) is
  a config error: `loadSettings` warns + drops the LATER entry (first
  listed wins). Same combo on the SAME action is a redundant duplicate:
  warned + dropped too. Cross-context same-combo pairs (Digit1 = skill in
  game / tool in editor) are LEGAL - kept silently. ONE exception: a drop
  whose LATER entry is an INJECTED default (the user rebound a combo a
  default for an unmentioned action also occupies - user Enter→skip vs
  injected confirm→Enter) is SILENT - nothing in the user's file is wrong,
  the injection re-runs every launch, and a warning would pop the same
  message every launch with nothing to repair. The startup repair write
  (see Binding overlay semantics) cleans a warned file on the same launch,
  so the popup explains itself once. The keybind UI prevents conflicts at
  assignment time (steal with a warning - see TODO → Keybind editor).
- **Synthetic key repeat is owned by the engine, not the OS.** A held key
  fires its first repeat after `key_repeat_initial_delay_microseconds` (300ms)
  then repeats at `key_repeat_interval_microseconds` (40ms), tracked in
  `InputState.key_repeat_state` and advanced by the real-clock delta passed
  into `translateInput`. Owning the cadence means players cannot gain a
  real-time advantage by twiddling OS key-repeat settings. Only the repeat
  whitelist fires on a synthetic edge: movement cursors, undo/redo, skip,
  error-scroll. Non-whitelisted bindings (skill slots, toggles, confirm/cancel)
  are press-only - the per-binding gate consults the whitelist
  (`actionRepeats`) for synthetic edges, so a held key never repeats them.
  Mouse buttons have no repeat.
- **Cursor nudges: edge trigger, held-derived vector, press-direction
  fallback.** The tile-cursor nudge (`resolveTileCursor`, the level/hub
  arm + the editor arm) fires on a `move_cursor_*` edge (press or
  whitelisted repeat) but derives its vector from HELD cursor keys
  (`cursor_direction`: opposites cancel, diagonals fire when either of
  the two held keys edges/repeats - two physical presses rarely land in
  one tick). A press landing while its opposite is still held - key
  rollover, what fast input actually does - cancels the vector to zero
  and would consume its edge with no movement and no re-fire (the
  opposite's release produces no edge); the fallback nudges by the REAL
  press edge's own direction instead (`cursor_press_direction`, derived
  per tick from the press arrays with synthetic repeats EXCLUDED -
  `actionPressedOnRealEdge`). Repeats keep the cancel: deliberately
  holding both opposites freezes the cursor, and the fallback cannot
  oscillate on per-key repeat-timer drift.
- **Replay safety.** Repeat state lives on `InputState` (off the undoable
  GameState), and the resulting actions produce the same events a single
  press would - replay records events, not input timing, so a held-key
  session and a tapped-key session record identical event histories.
- **Known minor caveat: drain multi-fire.** `frame()` passes one
  `player_input` to every `update()` in a multi-event drain (≤10ms budget).
  Edge-triggered anytime actions (undo/redo, cursor nudge) can therefore fire
  on each drain iteration within a single frame. For undo/redo this is
  self-limiting (the first undo clears the event stack, ending the drain); for
  cursor nudges it can burst a few tiles during a drain that overlaps a held
  arrow. Pre-existing for real key presses; repeat makes it visible on held
  keys too. Brief and harmless; revisit if felt.
- **Modal capture states: Escape cancels, Enter confirms.** While a modal
  state owns the keyboard - the focused text field
  (`translateInput`'s `text_edit` suppression), an active keybind edit
  (`keybind_edit` + `routeKeybindCapture`) - binding translation is
  suppressed and the state's SEAM owns the raw keys: Escape cancels
  (discard/close), Enter triggers the primary action (commit/confirm). The
  seam may consume Enter as ordinary input first (the text field's Enter
  commits the field; the keybind LISTENING phase captures Enter as the
  combo's key) - once the state is past capture, Enter confirms (a keybind
  PENDING proposal). New modal states follow the convention; when a second
  seam-driven confirmable surface appears, the shared flag/generalization
  gets extracted then (one consumer today - the same call as B-simple).
- **Settings persistence (user preferences).** Shipped defaults live in
  `data/default_settings.txt` (embedded, read-only). User preferences live in
  `~/.ziglop/settings.txt` (persistent dir, same format). At startup the
  loader reads defaults, then overlays the user file: scalars per-field (user
  value wins, missing keeps default); InputBindings overlay PER-ACTION (see
  Binding overlay semantics below). Writes
  are FULL-FORMAT (all sections including InputBindings) so the user file is
  the same format as the defaults. `Settings.camera_zoom` is the first
  persisted preference; other tunable fields mark dirty as their UI lands.
- **Binding overlay semantics.** Per-action, not per-key-combo: a user file's
  binding for an action replaces the default's binding for that action
  (rebind = replace, not duplicate; the entry's `context` line, if present,
  is ignored - contexts are derived from the action, see Binding
  contexts). Same-combo
  different-action pairs WITHIN one context are a config error in spirit;
  the loader does not flag them today (equal-specificity ties co-fire per
  the hybrid precedence rule) - across contexts they are fine and resolved
  by the context gate. One action → multiple combos is additive (skip can
  live on Space AND Enter). The overlay implements
  **full-set + migrate**: a user file with an InputBindings section carries
  the user's bindings for the actions it NAMES, plus INJECTED default
  bindings for every action it doesn't mention (load-time, in
  `loadSettings`) - so a new official binding (skip_level, future editor
  keys, a renamed action) reaches existing installs instead of being
  shadowed by the user file. A dropped entry (unknown action - dropped
  BEFORE the injection loop) equally counts as unmentioned, so its default
  is injected. Idempotent by construction: when the
  overlay SUCCEEDS but produces warnings (dropped bindings, unknown keys -
  `overlayUserSettings` sets `repair_write_needed`), `createSessionSetup`
  marks settings dirty (`state.markSettingsDirty`), so the next debounced
  write (always full-format, context lines included) fires ~1s after boot
  and persists the injected bindings + drops the stale lines - later loads
  see those actions as mentioned and nothing re-injects, so the startup
  warnings don't repeat every launch. The repair write is NOT triggered
  when the user file failed to parse or load (the overlay fell back to
  defaults; overwriting the file would discard possibly hand-recoverable
  content - the warning deliberately repeats until the player fixes or
  deletes the file), nor when the file is clean or missing (no
  write-on-load outside a repair). An old-name binding for a RENAMED
  action parses to nothing (unknown enum value, dropped at load with a
  warning) - the renamed action then counts as unmentioned and its new
  default is injected; the repair write drops the stale line from the
  file. Pre-release (one existing install), no alias map is carried for old
  names; if a rename ever touches a heavily customized action, add a
  one-time old-name→new-name alias step at load.
- **Debounced writes (`PendingWrite`).** A general debounce primitive on
  `SessionState` (settings, future editor autosave). `markWriteDirty(tag,
  write_fn, now)` coalesces by tag (a burst of changes → one write); the
  settings writer pair (`writeSettingsToFile` + `markSettingsDirty`) lives
  in `state.zig` next to the machinery, shared by preference-change
  persistence and the startup repair write. Debounce
  1s + max-wait 5s: a dirty mark fires after 1s of quiet, or immediately if
  dirty for >5s (so a continuous stream can't starve the write forever).
  `session_clock` (non-pause-gated, on SessionState) drives deadlines so
  writes fire even while the options menu is open. `frame()` fires elapsed
  writes each tick; it's the live path (replay goes through restoreTo/replayTo,
  not frame), so the `!replaying` gate is automatic. Native `run` defer + web
  `beforeunload` flush pending writes on shutdown (web best-effort - same
  limitation as the crash dump; a change-then-immediate-tab-close may lose
  the last debounced write).

### Escape overlay chain

Escape is one anytime action (`Action.escape`, previously
`toggle_options_menu` - renamed once the binding self-heal landed: an
install whose user settings.txt names the old action warns + drops it at
load and picks up the renamed action's default binding).
`handleEscapeKey` (input_handlers.zig) consumes it as a generic
"close the topmost overlay" chain: a walk down `escape_ladder`, a
topmost-first ordered array of `EscapeRung` values. With the overlay
stack, the chain collapsed to THREE rungs - the per-surface ladder
(tips, browser, settings, ...) is gone because the stack already knows
which overlay is topmost:

1. **Mission complete** (custom, view-derived `last_completed_mission`)
   - fires the overlay's Continue button's `dismiss_mission_complete` +
   drain. (Never co-rendered with mission fail - complete shows in the
   hub/editor, fail on a level; the order between them is cosmetic and
   pinned by the census.)
2. **Mission fail** (custom, view-derived `playerDead`) - fires the
   overlay's Exit Mission button's orchestrator (`player_exit_mission`
   + drain). Dead outside a level screen absorbs Escape outright (the
   chain must not fall through to opening the options menu).
3. **Pop the overlay stack** (custom) - closes the TOPMOST open entry of
   `open_overlays`: whatever was opened last, the same surface that
   draws on top (slot order IS z-order - the view's emission and the
   chain now read the same slot, so they cannot disagree). The close is
   the recorded `player_toggle_ui_surface` (the same event the surface's
   own buttons push), so Escape ≡ clicking its Back button.

The walk closes the first open rung; every rung empty opens the options
menu on ANY screen (the main-menu variant carries its own entries - see
below).

**The exclusion mirror.** The one per-surface decision left is stack
member vs middle panel: the middle panels (inventory/gear/skills/
entity_inspect) are deliberately NOT closed by Escape (their per-panel
toggles I/G/S are the close path; revisit if playtesting asks). A
comptime check pins `escape_excluded_surfaces` to the `MiddlePanelId`
set in BOTH directions - an entry that is not a middle panel, or a
middle panel missing from the list, fails the build - and the bucketing
itself is compiler-forced by `UiSurfaceState`'s exhaustive switches. The
derived test in input_tests_escape.zig walks every stackable surface
for its layered-close coverage automatically. This is the
machine-walked-truth rule (AGENTS → Build & Test) applied to the chain:
the census pins the view side, the mirror pins the escape side, and the
z-order agreement can no longer drift silently.

The error popup is more-modal still but never reaches the chain: the
`pending_error` gate at the top of `handleAnytimeInput` consumes
`dismiss_error` first. Mission fail/complete reuse the exact orchestrator
events their overlay buttons push (both routed through
`pushPlayerActionAndDrain`), so Escape ≡ clicking the button - recorded
player actions on the undo timeline.

### Console input (stdin - a scripted input channel, TAS-shaped)

The game reads stdin while it runs: launching from a terminal gives
terminal control alongside the game window; piping a script drives the
game. ANOTHER INPUT CHANNEL, not a dev tool - always on (no flag), native
only (web has no stdin; the node headless run is a later investigation).
An stdin-less launch (double-click, the mac app bundle) is immediate EOF -
the reader thread exits, zero cost.

- **Injection mirrors the engine's own synthetic-input model.** A reader
  thread blocks on stdin lines → parses → a queue; the frame driver (the
  shared `frame()`, right after the backend poll - native-only in effect,
  because only the native driver spawns a reader; on web the queue stays
  empty and the drain is a no-op) drains ONE COMMAND PER FRAME and merges
  its events into that frame's `PlatformInput` - the same per-frame,
  per-event cadence the synthetic key-repeat machinery uses. The queue is
  a single-producer single-consumer ring with atomic counters, not a
  mutex: Zig's std locks need an `Io` handle on BOTH threads and the
  game thread has none to give inside `frame()`; a SPSC ring needs none,
  and a full queue blocks the reader (yield-spin backpressure - a piped
  script faster than the drain can never drop or reorder commands).
  Everything downstream is the identical pipeline (`translateInput`,
  held-state tracking, context gating, `bindingFires`, `frame()`'s gate
  ordering, drains, recorded events) - no parallel path, no different
  rate, so console-driven gameplay is identical to played gameplay.
  Merged KEY/MOUSE IDS resolve to their canonical STATIC slices -
  `internedInputId` looks the id up in the producible-id tables (the same
  literals the backend's key mappings use) at merge time. Static lifetime
  is a hard requirement, not an optimization: `InputState.keys_held` /
  `key_repeat_state` RETAIN the id slice past the frame (a held key stays
  held until its `release`), and the frame arena resets every frame - an
  arena-duped id dangles there and the next held-state comparison reads
  dead memory (the bug this replaced: a live segfault in `isHeld`, plus
  silently vanishing held keys). Typed text is still arena-duped - it is
  consumed within the frame (the text-input router copies it into the
  field buffer), so the arena lifetime suffices. The merged events ARRAY
  is arena-owned on the same within-frame basis. Queue slots are reusable
  reader-thread memory, so merged events must never alias them; the
  popped command's bounded bytes are read at merge time only (the event
  carries the interned slice, not a view).
  Chords work across frames (`press ControlLeft`, then `press KeyQ` next
  frame - held-state persistence supplies the modifier, like a human
  pressing across a frame boundary); `release <id>` completes the held
  model (a key never released stays held - like holding a physical key).
- **Actions inject at the button seam, with KEYBIND firing cadence.**
  `action <name>` runs `applyAction` on the frame's PlayerInput - the
  same call the button-click path uses (context-free by design; the
  consumption sites gate themselves). ONE difference from a button click:
  the button path is once-per-frame (the release block clears
  `session.pressed_button`, so a second drain iteration can't re-fire),
  while the injected flag rides the frame's PlayerInput through every
  `update()` call in the drain - exactly the semantics a real key edge
  has (`translateInput` sets the flag once; the drain passes the same
  by-value copy to each `update()`; `handleAnytimeInput` runs per call).
  Deterministic either way; a script that wants to avoid landing on a
  multi-event drain frame spaces its commands with `wait`.
- **The console-ready prompt (`> `) - the GAME thread's marker that the
  channel can take the next line.** Printed at boot (native wiring, right
  after the output writer) and after each processed command whose frame
  drain left the queue EMPTY - so pasted multi-line input prompts once,
  after the last command, and a mid-script backlog stays silent. `quit`
  prints none (the process is exiting); mid-hold frames print none BY
  CONSTRUCTION (`wait`/`wait idle` arm inside `takeFrameCommand` and never
  reach the caller). The game thread prints it, never the reader: stdout
  has exactly one writer (the game thread, via the queue's output - the
  reader writes only stderr), and a reader-side prompt would race the
  next frame's dump output onto a stale prompt line. Gated on stdin being
  a TTY (`isTty` at wiring → `ConsoleQueue.interactive`) - "a human is
  typing at the other end" - which is exactly when a prompt is truthful:
  the channel itself stays always-on (a piped script drives identically,
  just unprompted - a prompt over a pipe invites typing the pipe can
  never receive), and an stdin-less launch (double-click, the mac bundle)
  prints nothing at all. The BOOT half of the discoverability surface:
  when interactive, the native driver prints one hint line ("console
  input on stdin - type help for the command list") + the first prompt
  at wiring - the prompt says a console exists, the hint says how to
  learn it.
- **ONE verb table owns the vocabulary (no hand-written lists).** The
  console's command set is a single comptime declaration, `verb_table`
  in console.zig: the parser DISPATCHES on each entry's `name`, `help`
  PRINTS the entries (columns aligned at comptime from the table's own
  widths), and every entry carries real `examples` that a both-ways
  test walks - every example is a working command line (the printed
  help shows only tested-working lines), and every `ConsoleCommand`
  variant is covered by at least one example (a new variant is a test
  failure until the help table covers it). There is no second list to
  drift against: the parser's accepted verbs ARE the table's names,
  and the unknown-verb / unknown-id errors point at `help` / `inputs`
  instead of inlining a stale list. Ids stay strict exact-match - one
  canonical spelling shared by command lines, session logs, and the
  settings bindings (an accepted alias would beg the reverse question
  of which spelling a dumped binding uses); the vocabulary is
  discoverable instead of forgiving.
- **The command set** (human readable + writable, both directions):
  `press <id>` / `release <id>` (any producible input id - the
  `producible_key_ids`/`producible_mouse_ids` vocabulary; an unknown id
  errors with the dead-binding advisory's message), `move <x> <y>`
  (pointer, reference space - the same space the backend maps the
  hardware pointer into via the letterbox inverse, so a coordinate
  clicks the same button at any window size / render resolution;
  the position PERSISTS across frames like held keys: the native
  backend re-reports the hardware pointer position EVERY frame
  (unconditionally), which would otherwise overwrite a scripted
  position before the next command lands, so every INPUT-command
  frame re-applies the remembered position ahead of the command's
  own events - last writer wins within the frame. Frames between
  commands stay on the hardware position, so a human at the window
  never loses the pointer; without a `move` yet, commands act at the
  hardware position), `scroll <delta>`, `type <text>` (the char
  queue - the text-input widget's own machinery consumes it; commit via
  the normal paths: `press Enter` or the M2 click rule), `action <name>`,
  `wait <n>` (skip n frames) / `wait idle` (hold until the game is
  idle - stack empty, no wait, no modal error, the same condition
  under which the game accepts player input - then release the next
  command on that first idle frame; the pacing primitive for scripted
  turn flow, where enemy turns drain over real-clock waits and a frame
  count is a guess), `dump <thing>`
  (plain text on stdout), `report ui` / `report level` (the curated
  projections - see the next bullet), `help` (the command list), `inputs`
  (every input id `press`/`release` accept - the producible-id tables
  themselves, printed; the same vocabulary the settings bindings name, and
  the category grouping emerges from the tables' existing order), `quit`. The `ui` dump lists the last-rendered interactive
  surfaces (buttons / sliders / text fields / ref-bearing slots) with
  their rects and CENTER points - a valid click point each, in reference
  space - so scripts are self-documenting: `dump ui`, read a center,
  `move` + `press`/`release` it (button lines carry the action name, the
  same enum `action <name>` accepts). The `level` dump lists the ACTIVE
  WORLD (level or hub) for gameplay decisions: turn phase, entities
  (team / health / aggro / tile), the phase's legal-target highlights
  (the game's own computed move/skill-targeting tiles - a script never
  reasons about legality, it clicks a highlight), the player's full
  8-slot skill bar (weapon + utility, the Digit1-8 numbering) +
  cooldowns, the ground stacks (walk onto the tile to pick up -
  kind + name + stats per item), the player's inventory, and the
  level-end flag / mission exits - each
  tile line with its CENTER, a click point projected through the frame's
  LIVE camera (`view.tileClickCenter`, the inverse of screenToTile, so a
  coordinate off the dump line resolves back to its tile). That is why
  the frame drain runs AFTER the frame's camera computation. Blank
  lines and `#` comments skip - scripts are annotatable.
  Verbs, ids, action names, and dump kinds are exact-match (they name
  enum values the engine consumes).
- **`dump <path>` - pure reflection over the live object graph (the
  `dump_walker.zig` seam).** A path is a Zig member-access expression
  evaluated read-only against the FrameState the driver holds - field
  names, union tag names, and `[n]` indexes: `dump
  history.current_state.hub.player.position`, `dump
  history.event_history.items[12].meta_event.wait`. The path IS the
  code's own addressing (that is why union tags are path segments -
  `.meta_event` is what the code writes), so names mirror the types
  exactly: renaming a field renames its dump path, and a dead path
  errors truthfully (`no field 'x' on types.Settings - fields: ...` -
  the error teaches the next path) instead of going stale. Bare `dump`
  renders the root table of contents (one level of field names - the
  discovery entry point); any deeper fact needs its path. An empty
  (uninhabited) union field - a "none yet" placeholder like
  `ReplayViewerEvent` - errors as `a union with no variants` (its
  `@field` access cannot even lower, so every walker recursion site
  comptime-guards with `isEmptyUnion`).
  Two dump classes share the verb: the PATH dumps above (machine-
  walked truth - new fields appear automatically, a lie is structurally
  impossible; this replaced the hand-written `state` / `settings` /
  `bindings` / `history` projections, which were hand-maintained
  serializations of typed objects - drift by definition), and the
  CURATED `report ui` / `report level` (derived facts that exist as no
  stored state - click centers, legal-target highlights). The verb
  split is the vocabulary making the two semantics visible: `dump` is
  purely the mirror, `report` is interpretation - and the pre-split
  spellings (`dump ui`) resolve as PATHS, erroring truthfully against
  the root (the redirect teaches the new verb).
  Rendering is type-determined - how a value prints depends only on
  its type, never on where the path ends: detail propagates through
  optionals/unions/slices (a union always shows through its active
  tag); struct fields cut to one-line summaries - the compact form
  when the value fits one line (`{ x: 5, y: 6 }`, `.meta_event .start_hub
  { hub_id: camp_at_the_crossroads, sets_checkpoint: true, completed_mission: null }`),
  else a summary token naming the type (`<types.ViewState>`, `([45 of
  types.Vector2])`). Leaf conventions are the session-log writer's
  (ints decimal, bools true/false, enums → tagName, strings verbatim).
  Addressed slices render element-per-line capped at 100 with an
  explicit `(+N more - address by index)` note; depth is never limited
  (the path scopes the dump, not a render rule). One known raw-but-
  truthful rendering: `std.EnumSet` values (e.g. `fired_actions`) show
  as their mask arrays - a nicer rendering would need `.contains()`
  (a METHOD call), which the no-method-calls invariant below forbids;
  do not "fix" this by calling methods.
  MEASUREMENT TRUST: when a console measurement contradicts a
  deterministic reading of the code, suspect the CHANNEL first - the
  instrument is newer than the game (its segfault era: nondeterministic
  dump truncation masquerading as game behavior - see DONE.md,
  console input id interning). The channel is measurement-grade since.
  SAFETY INVARIANTS (a dump must never mutate or execute - verified
  before the walker was built): the root is const-asserted (`*const`
  from `writeDump` down - mutation is a compile error); raw pointers
  are NEVER followed (`<pointer>`, so no vtable/allocator/function
  pointer is ever dereferenced and cycles are unreachable by
  construction); NO method is ever called on a walked value - field
  memory reads and `@typeInfo` only (a Zig method is arbitrary code;
  the walker's contract is that walking executes none); union descent
  is active-tag-checked (reading an inactive payload is UB - the
  mismatch is a truthful error instead); indexes are bounds-checked.
  A canary test walks a battery of deep paths over a real history and
  asserts the state bit-identical after. Known benign caveat:
  `console_queue`'s memory is written concurrently by the reader
  thread - dumping into it can display transiently torn values (never
  a crash, never a mutation).
- **The observability stash - per-frame facts the walker can't otherwise
  see.** The translated `PlayerInput` and the frame delta exist only
  DURING `frame()`; `FrameState.previous_player_input` /
  `previous_delta_microseconds` keep the previous frame's (written once
  per frame right after translateInput + the console fold - everything
  below only reads it), and `console_queue.last_taken_command` records
  which command the drain took (any kind, waits included). The
  `previous_` naming follows `previous_view_state`; a dump on frame N+1
  shows frame N, so `press X` followed by `dump
  previous_player_input...` asserts what the press DID. The stash is a
  plain wholesale copy - `PlayerInput` is all values except one string
  payload, and that payload (the `clicked_payload` union's `editor_sprite`
  variant) borrows
  SESSION-owned scan bytes (`MissionSprite.stored_id`, minted at the
  scan - see DESIGN → Architecture → Level Editor → the sprite
  picker), so nothing in the stash can dangle into the reset frame
  arena (the console id-lifetime lesson, applied at the data's owner
  instead of at the consumer).
- **Console sessions are ordinary sessions**: injected events produce
  normal recorded events, so a console-driven session's log is a valid
  `--replay` artifact - scripted setup doubles as fixture generation.
  Input is deterministic (one command per frame); replay determinism
  follows the event history as always.
- **What it tests**: everything from `PlatformInput` upward - the
  placement-class bugs the headless suite cannot see become drivable (the
  dead-Escape class: `press Escape` end-to-end; the wheel-after-the-gate
  class: `scroll 1` with the options menu open). BELOW the merge point -
  the raylib poll table itself - remains the comptime lockstep guard's
  territory.
- Key files: `src/console.zig` (raylib-free: parser + queue + merge +
  applyAction injection + dump projections - unit-tested in the test
  root), the per-frame drain + action fold in `main.frame` (the
  `applyFrameCommand` call right after the backend poll, the
  `foldInjectedActions` call right after `translateInput`), and the
  reader thread + stdout writer wiring in `src/native.zig`. Dump output
  is stored on the queue as the concrete `File.Writer` parent (the
  interface's vtable resolves its parent via `fieldParentPtr`, so an
  interface copy would dangle).

## Error Handling

A `@panic` (unrecoverable failure) dumps the live session as a session-log
BUNDLE to `crashes/crash_YYYYMMDD_HHMMSS/` in the persistent dir before
trapping - see "Crash dump" below.

Two error classes, with different responses:

- **Unrecoverable** - OOM, broken invariants, the `current.level.?` force-
  unwraps, replay-verification mismatch, a shipped/embedded file failing to
  parse (a real bug). Response: `@panic` (fail fast). The game can't
  continue, or the *code* is wrong.
- **Recoverable** - an I/O or parse failure on content that is effectively
  user-supplied at runtime: custom missions, player saves, session logs, AND
  shipped files overridden via the persistent-dir shadowing (a player/dev
  drops a broken file at `~/.ziglop/<shipped-path>` and the embedded copy is
  never reached - so "shipped content can't fail at runtime" is false by
  construction, not by accident). Response: warn + degrade/revert, never
  crash. See the three contexts below.

Never silently swallow (`catch {}`) - a dropped result becomes a confusing
silent bug. Allocation panics are written inline (e.g.
`catch @panic("failed to append event")`); OOM stays unrecoverable. The
recoverable path surfaces failures to the player via the error popup, not
silently.

**OOM never propagates as a config-layer error.** Allocation failure at
parser/loader/file-source sites panics inline - it is unrecoverable,
exactly as the class list above says, and an error return would let a
generic `catch` site mistake a fatal condition for a content problem
(the loadConfigWithFallback shape: an OOM inside loadSettings falling
through to default settings, whose debounced write could clobber the
player's settings file with defaults). Loader error unions therefore
carry INPUT problems (validation) only, and their errdefers guard
validation-error paths only - which is what makes every loader error
path reachable by crafted malformed content, and thus leak-check-
testable under `testing.allocator` with a malformed fixture (the parse →
expectError → freeParsedSections pattern). Panic paths need no errdefer:
panics skip them, and the dying process owns the partial build. The
crash dump (below) is the designed response.

### Recoverable error surface (the popup)

`SessionState.pending_error: ?[]const u8` (off the undoable GameState, so
replay-safe by construction) carries a message; `view()` renders it as a
modal centered popup (`ui.buildErrorPopup`), appended last so it draws on
top. `Action.dismiss_error` (bound to Escape + Enter, context `error_popup`)
clears it. `handleAnytimeInput` gates all input when a pending error is set
- only `dismiss_error` and the scroll actions get through; `update()` pauses
the game (drag/camera/wait/idle blocked), mirroring the overlay pause
(DESIGN → UI Framework → Modal overlays).
The message is duped into `history_arena` (durable across frames; overwrite
leaks the prior bytes - accepted, same unbounded-arena tradeoff as
`event_history`).

**Scrolling** follows the game-wide row-scroll convention (the inspector /
skills-panel / browser model): `error_scroll_offset` is the index of the
first visible body LINE, the wheel scrolls one line per notch with wheel-up
= earlier lines (offset decreases, lower-clamped at the input site), the
arrow keys (`error_scroll_up/down`) 3 lines per press, and the view clamps
the upper bound in place (authoritative - only it knows the wrapped line
count) and emits exactly the window's lines drawn from the top of the body
region. Whole visible lines only - the region height is the visible count ×
line height, so text placement is identical at every offset. Messages are
joined with `\n` (one warning per line); `wrapRow` treats `\n` as a HARD
line break and never emits it inside a span - raylib's `DrawTextEx` also
breaks on `\n`, but with its own line advance + x reset the layout never
reserved space for, which made overlapping lines before the fix (see
DONE.md). (The popup was
originally built with a pixel offset that predated every other scroller in
the game: the wheel sign was flipped, the window was drawn at its
unscrolled y, and the input step unit (a hardcoded 56px) didn't match the
view's `lineHeight` - see DONE.md.)

### Three contexts for recoverable failures

1. **Startup config** (`session_setup.zig`): settings, color themes, weapon
   types, salvage. Shadow parse fail → fall back to the embedded copy + warn;
   embedded fail → panic (real bug). All four loaders use
   `loadConfigWithFallback` + `FileSource.readEmbeddedFile`; warnings are
   collected and surfaced as a single `pending_error` popup after the history
   is created. Settings-overlay warnings additionally self-heal: the startup
   repair write rewrites the user's settings.txt full-format, so those
   warnings don't repeat next launch (see Input → Binding overlay semantics);
   warnings from the other config files (and from a user settings.txt that
   failed to load) deliberately persist until the underlying file is fixed.
2. **In-event reconstruction reads** (`start_mission` / `start_level` /
   `start_hub` / `load_save` / `open_editor`): these handlers return `!void`;
   a read OR parse failure is recoverable - `readReconstructionFile`
   propagates live read errors (a missing/unreadable file - e.g. a deleted
   autosave after the menu offered Continue, or a broken persistent-dir
   shadow of shipped content) instead of panicking, and the handler's
   `catch` turns it into `failReconstructionRead`. `processEvent` catches,
   the drain loop reverts to the last idle-point snapshot (guaranteed empty
   stack - `recordIdlePoint` only fires when `event_stack.len == 0`, so
   `restoreTo(last_idle)` replaces `current_state` wholesale with a
   stack-empty state, no clearing needed) and sets `pending_error`. OOM
   still panics. The other ~90 handlers stay `void` - invariant unwraps +
   gameplay logic failures are bugs → panic. (The cache-miss `@panic` in
   `readReconstructionFile` is a SEPARATE policy - it covers REPLAY cache
   misses, which are a bug (a live read that didn't cache, or a broken
   session-log bundle) or a genuinely unrecoverable read on the lazy-disk
   revalidate path, not live reads. Don't conflate the two.)
   - **Autosave-specific touch:** when `load_save` fails reading the
     autosave path, `session.autosave_available` is cleared so the
     Continue button disappears after the user dismisses the popup (no
     dead retry into the same error).
3. **Writes + reloads** (`save_game`, `dump_event_log`, session-log reload):
   on failure, warn + popup + abort the operation. The session-log
   `file_format_version` hard-gate can soften to warn-and-abort here.

### B-simple (per-dispatch recording, not transactional)

`recordEvent` + `discardFutureTimeline` stay per-dispatch (the current model:
`event_history` is always an exact real-time log; `current_event_index`
always points at a real committed position - a simple, robust invariant with
no "pending" state). On a handler failure mid-transaction, the drain loop
trims the failed transaction's recorded events
(`event_history.shrinkRetainingCapacity(current_event_index)`) and restores
the snapshot. **Known edge case:** if the player undoes, then triggers a
failing load, the redo future was already discarded by the first event's
`discardFutureTimeline` and is not restored - so redo is unavailable after a
failed post-undo action. Accepted: a minor UX asymmetry (no crash, no
corruption), in exchange for not restructuring the most determinism-critical
code (replay verification, the reconstruction cache's `current_event_index -
1` keying). The transactional alternative (defer append + discard to
transaction commit) was considered and rejected: its independent benefits
are marginal with no current consumer, and its costs land in replay-
verification code where a subtle bug is most damaging.

### Crash dump (panic → session log)

A `@panic` (invariant failure, OOM panic, replay-verification mismatch,
force-unwrap, safety check) dumps the live `event_history` + reconstruction
cache as a session-log BUNDLE to `crashes/crash_YYYYMMDD_HHMMSS/` in the
persistent dir before trapping. `event_history` is always a complete
real-time log (B-simple per-dispatch recording), so a crash bundle carries
every event up to the crash plus the embedded content of everything it
read - a fully reproducible, replayable session log (loadable by
`session_log_bundle.loadSessionLogBundle` - see Logging & Replay →
Session-log bundle) - just named `crash_*` instead of `session_*`.

- **Mechanism:** `src/crash_dump.zig` is a custom panic namespace installed
  as `pub const panic = crash_dump.panic;` in BOTH entry files (native.zig,
  web.zig - replacing web's prior `std.debug.simple_panic`). It mirrors
  simple_panic's full safety-check helper set, but `call` first prints the
  message to stderr, attempts the dump, THEN `@trap`s. A file-private global
  `crash_history: ?*GameStateHistory` is `install`ed by `main.run` (native)
  / `web.main` (web) at startup and `uninstall`ed at clean shutdown (native
  defer; web skips uninstall - tab close IS shutdown). null outside a session
  (e.g. a panic during startup config load) → the handler skips the dump.
- **Safety:** the dump uses `std.heap.page_allocator` for its OUTPUT buffer
  (never the game's arenas, which may be inconsistent at panic time). It
  READS `event_history.items` (history_arena-backed) - a panic is almost
  always a logic error, not heap corruption, so the arenas are normally
  intact. The io handle + persistent dir are entry-file-owned (independent
  of the game arenas), so reusing them is safe. Every failure in the dump
  path is swallowed - we're already crashing; the dump is a bonus, never a
  cascade.
- **Scope: Zig panics ONLY.** A raw segfault (wild pointer) bypasses this
  and goes straight to the OS - the arena/integer-only model makes that
  rare; a SIGSEGV signal handler is a separate, more invasive step we don't
  take.
- **Web is best-effort:** the persistent dir is in-memory only (the
  session-scoped storage model - see File System & IO → Web storage
  model), so a web crash bundle is a session artifact: catch it with
  Export Game before refreshing, or it is gone. Native is the reliable
  path. Accepted.

## File System & IO

The game ships as a SINGLE-FILE executable: all `data/` + `assets/` content is
embedded into the binary at build time. It runs from anywhere regardless of
the current working directory. Writable artifacts (saves, session logs, future
replays/custom missions) live in a persistent data directory, also independent
of cwd.

### File source (one unified source, session-resident)

ALL content + artifact reads go through ONE `FileSource` object living on
`GameStateHistory` next to `settings` (never deep-copied into snapshots,
never touched by replay). It exposes:
  - `readFile(allocator, path) -> []const u8` - reads against a normalized
    project-root-relative path (`"data/default_settings.txt"`, `"assets/world/tile.png"`).
    Hostile path shapes (absolute, `..` traversal, backslash, NUL, empty
    segment) read as `FileNotFound` - the seam's own path policy, defense
    in depth against crafted bundles seeding reads outside the content
    root (a must-have before the server seam).
  - `writeFile(path, bytes)` - writes to the persistent dir ONLY; rejects
    `data/`/`assets/` prefixes with a panic (shipped content is immutable
    from the game's perspective) and rejects the same hostile path shapes
    the same way (every write caller is a constant or an already-validated
    import path, so a violation is a programmer error).

Read order (first hit wins):
  1. in-memory VFS - uploaded zips / fetched custom missions (transient; not
     wired)
  2. persistent dir - the per-OS default (see Persistent path below)
  3. embedded map - `data/**` + `assets/**` baked into the exe at build time

A read of a shipped path with no persistent/VFS override hits layer 3. A read
of a save/log hits layer 2 (misses VFS + embedded). A read of a custom mission
hits layer 1 (VFS) or 2 (persisted missions/), depending on how it was
acquired.

### Embedding

`build.zig` walks `data/` + `assets/` and emits `generated_assets.zig`
(gitignored, at the PROJECT ROOT - same for `generated_sprite_metadata.zig`,
`generated_lookups.zig` lives in `src/`) with one `@embedFile` entry per file,
assembled into a `std.StaticStringMap([]const u8).initComptime` map keyed by
project-root-relative paths. The file lives at the project root (and is exposed
as a named module whose package root IS the project root) so `@embedFile` can
reach `data/` and `assets/` directly - no `../`. The build step re-runs every
`zig build`, so new files are picked up automatically; *content* edits to
existing files require a recompile (which `zig build run` does anyway).

### Persistent path

Per-OS defaults, resolved in `native.zig:resolvePersistentPath` (the single
site; `builtin.os.tag` switch):
- **Linux**: `~/.ziglop/` - a dotfile in `$HOME`, NOT XDG - chosen for
  player-discoverability of saves/custom content over convention.
- **macOS**: `~/Library/Application Support/ziglop/` - the platform convention
  for player-visible save data (Finder's Go→Folder knows it; the dotfile
  would be hidden in Finder). Same discoverability-over-convention
  reasoning, different platform convention.

Holds `autosave.txt`,
`saves/`, `logs/`, future `replays/` and `missions/`. Overridable via
`--data-dir` flag / `$ZIGLOP_DATA` env var (dev, portable installs, tests);
the flag wins over the env var, which wins over the default. For dev work,
prefer `zig build run -- --data-dir <scratch-dir>` so session logs and
autosaves don't mix into your real persistent play data. The Windows native
path is still DEFERRED (the same switch gains a `.windows` arm when that
build exists). Web (emscripten) is WIRED: web.zig mounts the IN-MEMORY
persistent dir (MEMFS at /ziglop - browser storage is never touched;
see Web storage model) and builds FileSource on that dir - same
read/write code path as native, just a different dir source.
The dir name (`ziglop`) rides the planned ziglop→taplop rename sweep - free
pre-release (no real players with saves yet); the rename adds one site per
platform default + the `$ZIGLOP_DATA` env var name.

### Web storage model (session-scoped in-memory storage + Import/Export Game)
The PILLAR (the project's Goal): the game is fully playable offline, and
players' files are player-owned - nothing is ever stored server-side. Web
services, when they land (leaderboards, the hosted custom-content browser),
connect only with explicit authentication and only for those web-dependent
features; the storage model below does not change when they do.

Browser storage is NOT a dependable home (why this model exists): IDBFS sits
on IndexedDB, which browsers treat as best-effort - storage-pressure eviction
deletes the least-recently-used origin's data; Safari deletes ALL
script-writable storage for a site the user hasn't visited in 7 days; quota
failures surface only in the ASYNC syncfs callback (the write "succeeds"
into the in-memory layer and the flush silently fails - nothing at
`writeFile` time ever sees the error); users clear site data. None of this
is fixable client-side: the `navigator.storage.persist()` JS call only reduces the
eviction risk (granted heuristically, no prompt), and nothing defeats the
Safari cap or manual clearing. The conclusion: the web build doesn't
MITIGATE browser storage - it never touches it at all.

So the web build does NOT persist between sessions BY DESIGN:

- **The persistent dir is an IN-MEMORY MOUNT.** web.zig mounts a plain
MEMFS directory at the virtual persistent path - the game touches NO
browser storage (no IDBFS, no IndexedDB, no syncfs; `-lidbfs.js` dropped
from the build). Nothing persists between sessions - a refresh (F5) IS a
session end. Within the session everything works unchanged from native:
autosave, debounced settings writes, timestamped backups, mission saves,
crash dumps - the whole persistent-dir machinery. Nothing touches ANY
database at all - not even to delete one. Because the mount is synchronous
MEMFS, the old two-phase boot gate is deleted - main() runs the full session
setup inline (history in DONE.md).
- **Import Game** (main menu, web only): a file picker uploads a full
game-folder zip (`ziglop.zip`), OVERLAID onto the persistent dir: same-path
files are overwritten by the zip (restore wins), files the zip doesn't
mention are kept (this session's new work survives - e.g. a custom mission
made this session). UNTRUSTED-ZIP RULES (the shared policy with the mission
import - `zip_reader.isUnsafeZipEntryName`/`isOsZipJunkEntry`): entry names
must be relative, `..`-free, NUL-free, non-absolute, backslash-free (a
backslash is a malformed or hostile name outright - a superset of
"`..`-free under both separators") - anything else ABORTS the import with
the recoverable popup naming the entry; OS-zip junk (directory entries,
`__MACOSX/`, `._*`, `.DS_Store`) is skipped so an OS "compress folder" zip
round-trips clean; every name + size cap is validated BEFORE the first
write and a full dry-run decode pass runs before the write pass, so a
hostile OR CORRUPT archive fails WHOLE - the first bad entry is found in
validation, nothing is ever written (never a half-applied overlay);
extraction STREAMS entry-by-entry (the reader's split API: central-
directory headers first, then one entry decoded + written + freed at a
time via a per-entry reset arena - memory = one entry), capped at
512 MB per entry / 2 GB total / 65,536 entries (a generous tripwire -
legitimate folders are a few MB; under the in-memory model the caps
protect a busy tab, not a quota); single-level extraction (no zip-in-zip
recursion); shadow trees (`data/`/`assets/` names under the persistent dir)
are ALLOWED - a restore of the player's own folder - written through the
RAW persistent-dir handle (not `FileSource.writeFile`, whose shipped-path
write guard panics by design); no post-import flush (nothing to flush
into). The picked zip lands at a FIXED staging temp (`.game_import.zip`)
+ the marker (`.game_import_marker`, body = the staging path - the upload
JS's write order: staging first, marker second); the staging zip is
deleted on every import exit (success + failure - the original stays
wherever the player picked it from), and BOTH temps plus every other
root artifact (markers, the staging zips) are excluded from the Export Game
listing via ONE machine-walked name set both walkers derive from (a
leftover must never ride in a later export). The marker is polled EVERY
FRAME on web (a comptime-gated call in the shared frame path) and consumed
whenever it lands, regardless of what screen is up: the re-boot happens
at that frame boundary - an import REPLACES the session, in-flight
progress since the last autosave included (the button being main-menu-
only keeps the realistic race to a sub-second window; the chosen behavior
is the honest one - apply the import the moment it completes). APPLICATION: a successful
import RE-BOOTSTRAPS the session - `rebootSession` (web.zig, at the frame
boundary): `crash_dump.uninstall` → `deinitAudio` → `freeSessionSetup`
(the teardown: the history's `deinit` + the tracked startup memory) →
the boot sequence (`createSessionSetup` + `fixupPointers` + `initAudio` +
`crash_dump.install`, shared with first boot via `bootSession`) so
everything the folder carries applies: settings (vsync at setup,
render resolution live-applies next frame), shadow `data/` trees (themes,
weapon types, salvage), and the autosave detection (Continue appears for
the imported autosave). The re-boot runs at a FRAME BOUNDARY via
`pending_import_reboot` (a mid-frame swap is a use-after-free of
the old history - the running frame holds references into it). The
TEARDOWN (a landed prerequisite, not a leak): `freeSessionSetup` frees
the frame arena, everything the history owns (its `deinit`: the
session-owned config values, the session lists + scan entries, the
snapshot/checkpoint/initial arenas, the two big arenas - the event log,
idle points, reconstruction cache, and pending_error all live in
`history_arena`), and the tracked startup memory (`StartupMemory`: every
retained config bytes + sections pair + the startup warnings - the
loaded values are freed FIRST, then the section containers, then the
raw bytes; the round-trip is leak-check-tested under testing.allocator).
The result is a fresh-boot state (open surfaces close, timeline resets) -
mechanically safe at any screen (the reboot happens between frames;
nothing renders or reads input against the old history after the flag
is consumed); the discarded session's live progress is the accepted
cost above. Known limitation: the leak-check test drives boot +
main-menu drain; a re-boot from a deeper session (scanned save lists,
the editor registry) relies on the deinit's symmetric frees (the
empty-list no-ops) rather than a driven test.
- **Export Game** (options menu, EVERY variant - the options menu is the
only menu surface reachable mid-level, so in-session backups are always
possible): a game in progress pushes the autosave write FIRST (the
`end_hub`/`end_level` `write_save` push - mid-level progress is IN the
export, not just the files already on disk), then zips the FULL persistent
dir (the "game folder": settings, saves including backups, custom missions,
logs) as `ziglop.zip` and triggers a browser download
(`triggerBrowserDownload`). The download is the only guaranteed-safe home
for web data - the bytes leave the browser entirely. (The file name
migrates with the game rename.)
- The ONE-FILE import/export flows (save files, mission STOREs) are
UNCHANGED - different verbs (sharing one save / one custom mission) than
the whole-game round-trip; both keep their existing homes.
- **The disclaimer** (main menu, centered above the title, web only) - the
chosen wording, four outlined lines at one font size (the import/export
sentence breaks at its phrase boundary so no line spans wider than
~1600px of the 3840px reference): `WEB DISCLAIMER:` / `Your saved data
does not persist between sessions on web.` / `Use the Import Game and
Export Game functionality` / `to load and save data for cross-session
usage.`.
- **Multi-tab is TRIVIAL**: the persistent dir is per-tab memory - tabs
share nothing at all (no database, no boot-clear races).
- **Migration: none.** At the time of the change there were zero web users
and the dev's own leftover was disposable: a brief interim build carried a
fire-and-forget `indexedDB.deleteDatabase('/ziglop')` call that wiped it on
first boot, then the line was removed - nothing touches a database at all
now, not even to delete one (history in DONE.md).

### Autosave

The autosave (`saves/autosave.txt`) is the recovery path for a player who
exits mid-session: `end_hub` / `end_level` push `write_save{autosave_path}`
before discarding the world, so progress is never lost to a crash or quit.
A NEW game overwrites it on the first subsequent `end_hub`/`end_level` - so
starting a new game while an autosave is present would silently destroy the
old save. To prevent that, `start_new_game` pushes a `backup_autosave`
MetaEvent (handler-gated `!replaying`, same side-effect convention as
`write_save`) that, when an autosave exists, copies it to
`saves/autosave-YYYYMMDD_HHMMSS.txt` (timestamp from
`formatSessionTimestamp`, same `YYYYMMDD_HHMMSS` format the crash dump uses).
The push happens AFTER `loadCampaignAndPushHub` so `backup_autosave` lands
ON TOP of `start_hub` on the event stack (LIFO → runs first). Pushing it
before would let `start_hub` run first, and its `transitionScreen(.hub)`
clears the event stack - wiping `backup_autosave` before it ever runs.
The player can later load a backup by pointing `load_save` at it (the load
path is arbitrary, not hardcoded to `autosave_path`). Best-effort: a backup
failure surfaces the error popup but does NOT abort the new game - the
backup is preservation, not a prerequisite. Collision (two new games within
the same wall-clock second produce the same filename) is accepted - the
second overwrites the first, a scenario implausible enough not to warrant a
suffix counter. The backup is a pure file copy (read autosave bytes → write
at the timestamped path); no PlayerData decode/encode, so it can't corrupt.
The reset-to-defaults settings backup follows this same policy
(`settings-backup-...` in the persistent root - see Input → Keybinds tab).
On web the autosave is SESSION-SCOPED (the in-memory persistent mount -
see Web storage model): it resumes within the session; Export Game is the
cross-session path.

### Raylib seam

`src/raylib/` stays the ONLY directory that `@import("raylib")`. The texture
cache reads bytes via `FileSource.readFile` →
`rl.loadImageFromMemory(".png", bytes)` → `rl.loadTextureFromImage` →
`rl.unloadImage`. The backend asks the source for
bytes; it never touches the filesystem directly. Same pattern holds for audio
later (`loadMusicStreamFromMemory` / `loadSoundFromWave`).

`native.zig` computes the persistent path (XDG override / flag / env / default),
constructs the `FileSource`, and passes it into `main.run`. `main.zig` and all
game logic stay path-agnostic.

### Web save export (browser download)

On web, a successful non-autosave `write_save` (the options-menu "Export
Save" button) triggers a browser download of the just-written file - the
player gets a save on disk without digging through IndexedDB. The seam is
`file_source.triggerBrowserDownload` (reads the file back from the emscripten
in-memory FS, anchor-clicks a Blob; comptime-dead on native so the extern
never links outside web builds). Design points:

- The AUTOSAVE never downloads - it is the IN-SESSION resume path (the
in-memory persistent dir is session-scoped - see Web storage model); a
download prompt per autosave would be noise. Same for `backup_autosave`
(preservation, not a player action).
- The timestamped save still lands in the in-memory persistent dir too - the
download is additive redundancy, not a replacement.
- Replay-gated upstream (`write_save` skips side effects while replaying), so
  undo/redo scrubbing can't re-fire downloads.
- The mount path constant is shared (`file_source.persistent_mount_path`)
  between web.zig's in-memory mount and the JS that builds absolute FS paths.
- Browser user-gesture policy could block a programmatic download if the
  click's activation expires before the handler runs; if that ever surfaces,
  the fix is a JS-side queued-download flag consumed on the next real pointer
  event. Pairs with the import path below.

### Load-save browser + web save import

The main-menu "Load Save" button opens a full-screen modal browser over the
main menu. Design points:

- **Scan lives in the input path, never in `view()`.** `FileSource.listSaveFiles`
  lists saves/ (all `*.txt`, autosave included - it's a legitimate load target)
  sorted newest-first by mtime (write-once files, so mtime ≡ creation time;
  name is the deterministic tiebreak). The list lives on
  `SessionState.save_files` (file-derived UI state, like
  `autosave_available`), owned by the backing allocator: each rescan frees
  the previous slice, so the only leak is the final list at process exit.
- **Rescan on open + every 500ms while open** (session-clock throttled -
  the pause-independent clock, so the throttle keeps ticking while the
  browser overlay freezes the animation clock), so
  files dropped into saves/ from outside appear live. The rescan runs AFTER
  the options_action dispatch in `handleAnytimeInput`: a `load_save_row`
  click's
  index refers to the list the clicked button was rendered from, and a rescan
  between the release dispatch (start of `update`) and the handler could
  otherwise shift the list under the index.
- **Rows carry their identity in the Button's click payload** (the
  `ButtonPayload.save_row` variant), since `Action` can't carry a
  payload. The release dispatch in main.zig folds it into
  `PlayerInput.clicked_payload` alongside the action. Save rows are never
  drag sources (they carry no `SlotRef`), so the drag machinery ignores
  them.
- **Clicking a row pushes `player_load_save{path}`** and drains it to
  completion (`pushPlayerActionAndDrain`) - the dispatch rides the anytime
  `options_action` path so it works while the browser overlay pauses
  `update()`. It's a PlayerInputEvent so
  the replay player-action whitelist stays a pure tag check; the handler
  pushes the ordinary meta `load_save` (acquisition already happened in the
  input path; the recorded event references a resident file). A failed load
  surfaces the recoverable popup and leaves the browser open.
- **Scrolling is whole rows**: the offset is in rows, clamped in the builder
  (the view is the only place that knows the max); one wheel notch = one row
  pitch, so text placement is identical at every offset. Only the visible row
  window is emitted (error-popup windowing pattern).
- **Web import ("Import External Save", bottom-right; web only)**:
  `triggerBrowserUpload` opens a file picker; the JS writes the picked file
  into saves/ under its sanitized name, then writes
  `.import_marker` (persistent-dir root, outside saves/ so the scan never
  sees it) containing the path. The Zig side polls the marker while the
  browser is open (the anytime pre-gate block - the acquisition-step rule),
  deletes it, and
  loads the path through the normal `player_load_save` flow (drained to
  completion; the load's screen transition closes the browser). Write order
  (save then marker) guarantees the bytes exist when the marker does; a name
  collision overwrites (importing your own export is the primary case).
  Native has no import button - drop files into the persistent saves/ dir by
  hand; the periodic rescan picks them up.
- The browser auto-closes on a successful load via the screen-transition UI
  reset (`ui_state = .{}` when the screen leaves main_menu).

### Modding by shadowing (side effect, not a designed feature)

Because the read order checks the persistent dir BEFORE the embedded map, a
player can drop a file at `~/.ziglop/<shipped-path>` to shadow shipped
content, or add new paths (e.g. `~/.ziglop/assets/weapons/my_new_sword.png`)
for new sprites/campaigns. Audio shadows may be `.wav` or `.ogg` (see
Audio → File formats). This is a side effect of the unified-source
layering, NOT a designed modding feature: no policy on which paths are
overridable, no verification, no safe-mode flag. It's accepted as-is for now;
revisit and add structure (override policy, verification, a disable-for-
troubleshooting flag) only if modding becomes a real goal.

### Migration (done)

The migration described above is complete: `history.directory` is gone,
replaced by the `FileSource` on `GameStateHistory` plus a sibling `io:
std.Io` handle (kept separate because `std.Io` is broader than file I/O -
callers that need the clock, e.g. `formatSessionTimestamp`, read it directly,
not through the file abstraction). All call sites across `main.zig`,
`event_handlers.zig`, `input_handlers.zig`, `parser.zig`, and
`src/raylib/` (the texture + font loaders) go through the source. Parser tests read `data/...` from
the embedded map, so the test build is hermetic. The VFS layer (layer 1 of
the read order) is the only piece still outstanding - it lands with
custom-mission support.

### Settings ownership (loadSettings is self-owned)

`loaders.loadSettings` DUPES each `input_name` into the passed allocator, so
the returned `Settings` OWNS its `InputBindings` strings - it does not
borrow from the raw file buffer. This is the durable fix for the mangled-
settings bug (where `overlayUserSettings` freed `user_bytes` while the merged
bindings still borrowed into it) and the general direction for any loader
whose result outlives the bytes it was parsed from: make the result
self-owned so the caller may free the raw bytes immediately. When
`loadSettings` replaces a base's bindings (overlay path), it frees the base's
owned strings + slice - so re-overlay doesn't leak the old names.
`loaders.freeSettings(settings, allocator)` frees a `Settings`' bindings
(strings + slice); used in tests under `testing.allocator`, never in
production (settings live for the session).

`loadConfigWithFallback` still leaks the raw config bytes + parsed sections
for process lifetime (it's generic over `T`, can't selectively free). After
the ownership fix the `Settings` it returns no longer references those bytes -
they're unreferenced garbage that stays leaked (fine, process lifetime).
`loadHub` + `loadCampaign` are self-owned as well (the campaign-editor
slice 1 rider): every returned field is duped into the passed allocator and
freed by `freeHub`/`freeCampaign` (tests only; production allocates into the
history arenas). Their tests hold the ownership contract - the parse
sections are freed BEFORE the assertions, so a borrow would be a
use-after-free by construction. The remaining loaders (levels, missions,
themes) still borrow into the leaked bytes; making them self-owned is the
same direction, landing with the load change that touches them
(`loadMission` rides campaign-editor slice 1's mission.txt step). See AGENTS
→ Build & Test → Testing discipline for why the leak matters for tests.

### Reconstruction cache (deterministic replay over mutable files)

Reconstruction-read event handlers (`start_level` / `start_hub` /
`start_mission` / `load_save` / future `start_editor`) read config files whose
results become part of the reconstructed state. Without a cache, replay
re-reads from disk - fine for shipped content (immutable) but WRONG for
files that can change mid-session (the editor overwriting a custom mission's
files, then undo back across the editor-open read). The cache makes the bytes
a reconstruction-read event applies a **pure function of its position in
history**, so replay is deterministic regardless of later file changes.

- `GameStateHistory.reconstruction_cache`: an append-only list of
  `(event_index, path, bytes)` entries in `history_arena` (durable, same
  lifetime as `event_history`; never in snapshots; never touched by replay).
- `GameStateHistory.readReconstructionFile(path) -> ![]const u8` is what
  reconstruction-read handlers call INSTEAD of `file_source.readFile`. **Live**
  (`!replaying`): reads via `file_source` into `history_arena`, caches, returns;
  a read error is PROPAGATED (recoverable - see Error Handling → context 2).
  **Replay** (`replaying`): binary-searches by event index, linear-scans within
  the event for the path, returns the cached bytes.
- The key is `(current_event_index - 1, path)` - `processEvent` increments
  `current_event_index` before dispatch, so the event under handling is at
  `current_event_index - 1` (identical in live and replay). A single handler
  may read several files; the path distinguishes them.
- **Cache-miss policy:** a miss is always a bug → `@panic` (fail fast, never
  silently fall back to disk, which would reintroduce divergence quieter)
  - EXCEPT the lazy-disk policy (`reconstruction_disk_fallback`, set only by
  `reconstructFromEventLog(.lazy_disk)` - the revalidate path). There the
  validation replay deliberately carries no embedded cache: a miss reads
  the mission's CURRENT file (the intended content, hash-gated upstream)
  and caches it retroactively. Session-log bundles
  (`reconstructFromEventLog(.authoritative)`) pre-populate the cache from
  the bundle's embedded copies via `loadReconstructionCache`, so a miss
  means a broken or hand-edited bundle - see Logging & Replay →
  Session-log bundle.
- `discardFutureTimeline` trims cache entries ahead of a branch (monotonic by
  event index, so shrink from the end), alongside `event_history` /
  `idle_points` / snapshots / checkpoints.
- **Serialized into the session-log bundle** (Logging & Replay →
  Session-log bundle): the manifest is the cache's on-disk form - every
  cached read as `content/` byte copies - and cross-session replay
  pre-populates the in-memory cache from it before replaying.

Editor consequence: editor-open reads go through the cache → undo past
editor-open replays the reads → cache hits → original bytes, regardless of
later saves. Editor edits are events mutating in-memory mission/level state
in `GameState` (captured by `deepCopy`, undo/redo by construction). Editor
save-to-disk is a **side effect gated on `!replaying`** (same convention as
`save_game` / `dump_event_log`) → undo never re-writes files. No
editor-specific undo machinery needed.

### Config grammar (per-format section headers + counted layouts)

`parseConfigFile` takes the file type's expected section headers as a
parameter - ONE list per format, and it is both the grammar (which lines
open sections) and the validation (which sections are legal): the same
set by construction, so they cannot drift. There is no global header
whitelist. A header-shaped line (uppercase-initial, after a blank line)
that isn't in the list errors (UnknownSectionHeader) naming the line -
never the old silent misparse into the previous section with misleading
unknown-key warnings. Inside a Layout, header-shaped lines are always
row content. `#`-comment lines are skipped; any other non-conforming
line outside a Layout (not key-value, not a header) errors too.

Layouts are raw character grids, and their termination must be
information a row cannot forge: decoration `character_code`s can be any
printable ASCII char (the writer's 91-code pool), so a row can spell ANY
section header - no content-matching rule can end a Layout safely, and
blank-line termination fails the same way (an empty row followed by a
header-spelling row is textually identical to a section separator - a
valid layout the format could not express). The grammar that works: the
OPENING line carries the row count, `Layout 12`, and the parser consumes
exactly that many raw lines; blank lines are empty rows (row index is
the y coordinate); nothing a row contains can end the section. The count
is at least 1: a layout always contains the `!` player spawn (both
formats), plus `=` in levels - `Layout 0` errors. A bare
`Layout` line selects the LEGACY grammar (terminate at the next
recognized header) for pre-count files; the choice is made by the
opening line's shape, so no version pre-scan is needed. Legacy files
keep loading forever (old user missions, embedded session-log content
copies); an editor re-save upgrades them to the counted form.

Version pairing: `file_format_version` is a supported RANGE per type
(levels 1-2, hubs 2-3) - newer-than-current errors as before, older
loads with the legacy grammar, and a CURRENT-version file with a bare
`Layout` errors (UncountedLayout, enforced in the loaders: the parser
records the declared count on the Layout section -
`Section.layout_row_count` - and a current-version file with a null count
is a hand-authored file that forgot it). The
layout READERS accept only the fixed specials (`' '`, `'.'`, `'!'`,
`'='`) plus the file's own defined codes - a typo'd `character_code` is
a truthful load error (UnknownLayoutCharacter), not a silent walkable
tile - and require the markers: `!` (player spawn) in both formats, `=`
(level end) in levels; a missing marker errors instead of silently
skipping the spawn-relative normalization. One leniency distinction: a
code whose DEFINITION ENTRY exists but was warned + dropped (a hub NPC
with an unknown npc_type) keeps its tile walkable - the entry's own
warn+drop policy already fired, and hard-erroring at the walk would make
the same defect fatal or not depending on whether the broken NPC happens
to be placed.

Rejected alternatives: the comptime lockstep guard (guards a duplicate
instead of deleting it - the global list was the bug); a reserved
terminator symbol (every printable char is assignable, so soundness
would require shrinking the code pool AND reader tightening);
declared height in Metadata (needs a cross-section pre-scan; the count
on the opening line is local).

## Custom Missions & Online Services

Custom missions are player-authored content that runs through the SAME
engine path as official missions. The framing is diegetic: a custom mission
is a "dream," accessed via a dreamguide NPC (guided meditation). Design is
settled; implementation is mostly pending (the VFS layer is the foundation).

### Dreams (custom missions in play)

- **A dream is a normal mission run**, NOT editor playtest. Rewards persist
  into PlayerData (gear/skills picked up carry back to the campaign). The
  editor's playtest/validate discard machinery is NOT reused - it stays
  scoped to the editor. A dream uses `start_mission` → `start_level` →
  `build_player_from_data` (sync campaign PlayerData in), and `end_level` →
  `build_data_from_player` (sync entity back out) → `end_mission`, exactly
  like an official mission. Custom missions ARE official content in spirit
  (the shipped campaign is one locally-bundled set showcasing all skills);
  the only differences are file source + return target.
- **File source:** the VFS layer (layer 1 of the FileSource read order) or
  the persistent `missions/` dir, NOT the embedded map. This is the
  outstanding VFS piece from File System & IO.
- **Return target = where the player was when they opened the browser**
  (a dream's mission.txt carries no hub endpoints - the campaign graph
  owns edges, and a dream is no campaign edge). In-hub / in-world-map /
  in-level launch → return to `player_data.current_hub` (the dream launch
  passes `end_hub_id = null`; the entering-hub fallback covers the
  return). Main-menu launch → return to the main menu (don't drop the
  player into the campaign world via a dream).
- **Main-menu launch requires a save pick** (existing save or new game) before
  `start_mission` - you need a character to dream with. Reuses the existing
  `load_save` / `start_new_game` machinery; the browser feeds into it.
- **Edge case:** a brand-new player with no hub visited has `current_hub =
  ""`. A dream from main menu is gated on having a Continue-able save; from
  a hub you're already in one.

### Browser (the custom-mission selector)

- A new full-screen overlay (alongside `world_map` / `full_combat_log`
  in the overlay stack). Reachable from three triggers, one UI:
  1. The dreamguide NPC in any hub (diegetic entry).
  2. The main menu (a button alongside New Game / Continue).
  3. The world map.
- Tabs/content:
  - **Acquired missions** (already in the persistent `missions/`
    dir) - click to start. Enumerated via
    `FileSource.listMissions` (see below).
  - **Online browse** (fetch list from the database, preview metadata,
    download into the persistent dir) - only once online services ship;
    absent/disabled until then. Fetch-to-local-then-play so no active
    connection is needed after download.
  - **Import from file** (zip upload / local path) - the offline sharing
    path, always available, no account needed.
- **Folder convention:** `missions/<id>/` where `<id>` is the folder
  name. Editor-saved and online-downloaded missions use `<uuid>_<slug>`
  (UUID generated at mission creation, stored in `mission_uuid` in
  mission.txt, stable across re-saves; slug derived from the display name).
  Hand-placed folders with any name are ALSO accepted (the id is whatever
  the folder is named) - generation/download follow the convention, reading
  tolerates anything. Two authors making "Skeleton Attack" get different
  UUIDs → different folders, no collision.
- **`FileSource.listMissions`** (file_source.zig): enumerates
  `missions/` in the persistent dir, returns `[]FileSource.MissionEntry`.
  Each entry: `id` (folder name), `path` ("missions/<id>" - as
  `open_editor`/`start_mission` consume it), `name` + `level_count` (from
  mission.txt),
  `has_custom_assets` (true if the folder has any file beyond mission.txt /
  player.txt / level_*.txt), `author_turns: ?u32` (null = unvalidated, until
  the validation replay format lands). Folders without a readable
  mission.txt are SKIPPED (broken/half-installed missions aren't offered).
  Persistent-dir only (no VFS - the local collection is the source of
  truth; transient acquisitions persist into this dir first). The EDITOR's
  editor browser reuses this scan for its Your Missions tab; the dream
  browser will reuse it too. `FileSource.listOfficialMissions` is the
  Official-tab sibling (comptime embedded path list + runtime metadata
  parse, same entry shape).

### Content identity

Three identity axes here - the hash scope, the challenge identity, the
version identity - plus a server-assigned publishable ID. (The authored
uuid, the cross-version identity, is the fourth axis: Campaigns & the
Campaign Editor → Content identity (uuids everywhere).)

- **The artifact file set (what every hash below covers):** the canonical
  ARTIFACT - exactly the file set the export bundles and a downloader
  receives: `mission.txt`, `player.txt` (optional), `level_1..level_N.txt`,
  every PNG in the mission folder, and `validation_replay.txt` (when
  present). The manifest IS the export list; it grows only with what
  export bundles (audio when it exists). Stray files in the folder
  (author notes, OS junk) are in NO hash: identity follows the artifact,
  not the raw folder - the server only ever sees the artifact, so the
  client's "what changed" must match the server's byte-for-byte.
  Invariant: the version-hash set = the content-hash set + the record
  files.
- **Content hash (local, derived - the CHALLENGE identity):** SHA-256 over
  the artifact MINUS the game-written records (`validation_replay.txt`).
  Canonicalization: sort file paths lexicographically, hash each file as a
  path-prefixed entry (`<path>\n<bytes>`), concatenate, SHA-256. NO
  line-ending normalization for now (our files are authored consistently);
  tighten only if cross-platform drift shows up. The hash is a DERIVED
  property (computed on demand), not a stored field on Mission. The record
  exclusion is what makes replay pinning non-circular: the content hash is
  stored INSIDE the validation replay (the staleness gate), so hashing the
  replay into it would make every just-written replay stale on arrival.
  Load-bearing for replay pinning in two places: the session-log bundle's
  manifest carries a PER-FILE SHA-256 (the integrity check + dedup key of
  the embedded copies - see Logging & Replay → Session-log bundle), and
  this mission-level content hash gates the validation replay's staleness
  (a mission edited since its replay was recorded shows "unvalidated" -
  see Validation replay below) + the personal-best overwrite decision.
  Mission leaderboards key by `(mission_uuid, content_hash)`: boards
  re-key on content edits ONLY - an author re-validating unchanged
  content keeps the same key (the medal targets update under it). Pure
  local, no server needed.
- **Version hash (the WHOLE-ARTIFACT identity, for server versioning):**
  SHA-256 over the ENTIRE artifact set, no exclusions - the validation
  replay included. NEVER stored inside the artifact (computed at upload
  time); nothing inside the artifact pins it, so there is no circularity.
  The server's version-dedup key: an upload under an existing uuid
  creates a new version iff the version hash differs. Content-hash-equal
  + version-hash-different is exactly the re-validation case (new author
  medal targets, unchanged gameplay content) - keying versions by the
  content hash would reject that upload as a duplicate and strand the
  author's improved PB on their own machine. The replay's embedded
  `created` timestamp means every re-validation changes bytes even for an
  identical run - one version per re-validation is ACCEPTED (a new replay
  is a new artifact; version histories show "content unchanged, medals
  updated" entries).
- **Publishable ID (server-assigned, stable across versions):** a UUID/slug
  assigned at publish time, with each version carrying its own version
  hash. A leaderboard entry pins to a challenge (content hash); a
  mission's profile page aggregates versions. Out of scope until the
  server seam lands.

### Turn counters + author medals

Two turn counters, incremented in the player's `turn_start` (entity_index 0)
handler:

- **Per-mission (`Mission.turns_spent`):** scopes a single playthrough. Used
  by the mission-complete screen for mission stats, and by the validation
  replay's author medal target. Discarded with the mission on exit (editor
  playtest/validate are discard-semantics, so it naturally doesn't persist
  there). Increments when the player's turn BEGINS, in any mode - counting
  at start (not end) means the final turn, spent walking onto the level
  exit and never reaching `turn_end` (the end_level transition clears
  the stack mid-turn), still counts; at any idle moment the counter
  includes the in-progress turn.
- **Cumulative (`PlayerData.turns`):** lifetime turns across the campaign,
  for historical stats. SKIPPED in editor playtest/validate (guard:
  `current.editor == null`) - the editor session must not inflate the
  player's real turn count. Persists via PlayerData (synced on save like
  other PlayerData fields; NOT synced through `build_data_from_player`
  since it's a direct PlayerData field, not an entity field).

Both are direct GameState writes inside an event handler → reproduced on
replay.

**Author medals (Trackmania-style).** When an author validates a custom
mission, the validation run's turn count becomes the **author medal target**
(the time to beat). Gold/silver/bronze are DERIVED from it by constant
multipliers, computed at read time (not stored):
  - gold = ceil(author_turns × 1.2)
  - silver = ceil(author_turns × 2.0)
  - bronze = ceil(author_turns × 5.0)
Ceil (round up) so a medal target is always at least 1 turn more than the
faster tier (very low author times can make tiers collide - accepted edge
case). Multipliers live as constants in the file that uses them (the browser
UI / mission-complete screen, when those land). The author time is DERIVED
from the replay's events at read time (count the player's `turn_start`s -
see Validation replay below), never stored anywhere, so it can't drift
from the truth of the replay; the derived count must equal the
replay-reproduced `Mission.turns_spent` (test-asserted). Medal derivation
is a pure function of author_turns, so the browser/mission-complete
derive at display time. A mission with no validation replay - or one
whose content hash no longer matches the mission - shows "unvalidated"
(no medals).

### Validation replay (the mission-dir artifact + personal best)

The validation replay is a session-log-format file at
`<mission dir>/validation_replay.txt`, written by the `end_validation`
success handler as a `!replaying`-gated side effect (the `save_game`
class - it has a recorded event, so live-only by the standard gate; the
dir comes from `current.mission.?.path`, no session state at write time).
See DESIGN → Level Editor (playtest/validate framing + the exit guard)
for the run-side design.

- **The slice = `event_history` from the LAST `player_start_validation`
  through the final `end_validation{success=true}`.** Because the
  validate-restart re-entry rides the ORCHESTRATOR (not the machinery
  event), every attempt in the linear stream begins with a top-level,
  seedable player action - so "the last one" is the final attempt's
  start, and restarts are excluded BY CONSTRUCTION: any restart inside a
  candidate slice would have produced a later `player_start_validation`,
  which would then be the slice start. No synthetic events, no log
  editing - the file is a verbatim contiguous slice of `event_history`.
  Restarting is a clean boundary precisely because `start_validation`
  needs no prior state (it reads everything from files): a fresh-state
  reconstruction of the final attempt ≡ the live re-entry.
- **Self-contained given the mission files.** Reconstruction = fresh
  state, seed the slice's events; every top-level event passes the
  two-layer gates (`isPlayerAction` + `validatePlayerAction`) as-is -
  the `player_start_validation` legality arm is "no active
  level/mission", which a fresh state satisfies. The reconstruction
  cache is NOT embedded in the file: the mission files always ship
  alongside the replay (the mission dir, the export zip, the server
  upload), and the metadata `content_hash` guards version skew (replay
  from content v1 + mission v2 → hash mismatch → "unvalidated").
  Session-log `file_format_version` 2 cache serialization stays what it
  already was - the plan for general session-log sharing - unchanged by
  this.
- **Turns are DERIVED, never stored** (see Turn counters above): count
  the slice's `turn_start{entity_index = 0}` events
  (`validation_replay.deriveValidationTurns`). The future server-side
  check reuses exactly this machinery: run the slice through
  `reconstructFromEventLog` headlessly (the test build already is
  headless - the crown test is the client-side prototype of the server
  check) and read `turns_spent` off the reconstructed state.
- **Revalidate (the re-certify path).** `player_revalidate_mission`
  (the editor's options menu - save first, the Validate contract: the
  check certifies the saved files) re-certifies a stored replay against
  the mission dir's CURRENT content: load the file, gate on the uuid
  identity, replay the run in CHECKING MODE
  (`reconstructFromEventLogChecking` - see DESIGN → Determinism &
  Tiebreaking → Replay CHECKING mode) against the files as they are
  now, and on success REWRITE the file with the same events + the NEW
  `content_hash` (the original `created` stamp + derived turns are
  kept - same run, re-certified). The criterion is strict replay
  verification: benign edits the run never touches (a decoration placed
  off the playable area - positions are spawn-relative, see DESIGN →
  Logging & Replay → Spawn-relative coordinates - or a rename) replay
  identically and pass; anything that changes what the handlers would
  push diverges and rejects (the old file is KEPT - it still certifies
  the content it was recorded against). `validation_replay.
  revalidateMission` is pure (file reads only; the handler owns the
  rewrite) and is deliberately the shape the future server-side upload
  validation wants: the same error-returning path, no fail-fast
  wrapper. The orchestrator is entirely live-only (`!replaying`) - the
  check reads current files, not recorded state.
- **Personal-best overwrite guard** (the clone auto-save pattern -
  auto-write on strictly-better, else offer manual overwrite): at
  `end_validation` success, build the new replay bytes + derive the new
  turns, then read the existing `validation_replay.txt`. Auto-WRITE when
  the old file is absent/unparseable, its content hash no longer matches
  the mission (an earlier mission version - the old replay certifies
  different content), or the new run is strictly faster (ties keep the
  old file - first-validated wins). Otherwise KEEP the old file, stash
  the new bytes on SessionState + set an overwrite-offered flag → the
  validation stats screen shows an Overwrite Replay button that writes
  the STASHED bytes (not a re-slice of `event_history` - the stash stays
  valid across later editor actions or undo that could trim the
  timeline). The decision is a pure helper
  (`validation_replay.replayOverwriteDecision`), directly tested.
- **The validation stats screen** is the mission-complete overlay rendered
  OVER THE EDITOR: `end_validation{success=true}` populates
  `last_completed_mission` (`MissionCompleteInfo.validation = true`), and
  `view()` draws the overlay whenever the info is set - no hub gating, so
  the campaign and validation variants share one surface with
  context-branched content. The validation variant swaps the clone
  summary/harvest for a "Validated in N turns - Personal best: M turns"
  line + the medal ladder (Author / Gold / Silver / Bronze - the Author
  row shows the author's own validated turns, the SAME value the targets
  derive from), and the buttons are Continue /
  Validate Again (the same action as the top-bar Validate button - saves
  first, then re-runs) / Overwrite Replay (while offered - writes the
  stashed bytes; the stash is SELF-DESCRIBING, its first event names the
  mission dir, so the write needs no session memo). The personal-best /
  medal context is session-side (`validation_personal_best_turns`,
  captured at the write site in both guard branches; view stays
  file-free) while the stats + the validation flag ride GameState with
  the info (replay-reproduced; the overlay itself is view-side).

### Balance bounds (parse-time, warn + clamp)

All gear-stat variables (health, defense, damage, speed, etc.) have UNIFORM
`max_*` constants (one set for ALL content - official + custom; "custom
missions ARE official content" supports uniform bounds). Every parsed
gear-stat field routes through `boundedU32`, which **clamps out-of-range
values to the max and appends a warning** (so the game stays playable + the
author is told). Parse time is the single chokepoint: enemy gear definitions in
level files ARE the loot table (enemies drop their entire inventory + equipped
gear + a skill tome per equipped utility skill), and that loot persists into
PlayerData - so bounding enemy gear stats at parse bounds what can ever enter
the campaign.

- Warn + clamp (not fail-fast panic) so a broken file doesn't crash the game -
  the player sees a popup naming the field, value, file, and max, then the game
  continues with the clamped value. Matches the recoverable-error policy
  (DESIGN → Error Handling): the warning surfaces via `setPendingError` (the
  same popup as key validation), and the clamped value keeps the game playable.
- Editor `validate` mode catches over-max stats pre-publish (the validator
  runs the mission; a warning = "fix your mission"). Local import catches it
  on load (honest "broken mission" feedback, same spirit as the magenta-box
  fallback for missing art - don't hide the problem).
- The constants live in parser.zig (the parse-time chokepoint): `max_weapon_damage`
  (10), `max_spell_damage` (10), `max_health_bonus` (10, for coat/gloves/
  pants/boots health bonuses), `max_defense_bonus` (5, coat), `max_gloves_damage`
  (5), `max_pickup_radius` (5, pants), `max_boots_speed` (2). Entity base
  stats (max_health, defense, speed, aggro_range) are NOT bounded - only gear
  stats. `boundedU32(value_str, max, field_name, file_path, warnings, allocator)`
  is the helper; a null `warnings` list clamps silently (the test path).

### Custom-asset paths (the id IS the location)

A custom sprite id is CONTENT-ADDRESSED: the segment chain after `custom/`
IS the file's location, relative to the content root, minus the `.png`
(`file_source.customAssetTail` - the ONE resolution rule, shared by the
loader's dims read and the texture store's byte read so the two can never
drift again):

- dreams: `custom/missions/<mission-dir>/<stem>` (persistent
  `missions/<mission-dir>/<stem>.png`)
- campaign-bundled art: `custom/campaigns/<campaign>/missions|hubs/<dir>/<stem>`
  (embedded `data/campaigns/...` for the official campaign, persistent
  `campaigns/...` for custom campaigns)

`FileSource.readFile` resolves those paths across both tiers: persistent
dir first, then embedded as-is (`assets/...`), then embedded under a
`data/` prefix (the campaign-content bridge). Minting goes through
`file_source.customStemForContentPath` (the inverse; a leading `data/` is
stripped) - the editor scan mints dream ids from the mission's path, the
future hub editor mints hub ids the same way, and the save's stem
normalization (`normalizedCustomStem`) rewrites stale paths to the save
target while the save's art copy carries the bytes there.

Why the id must carry the full path (not a dir name + context): the
texture cache keys by sprite id with no knowledge of what's currently
loaded, so ids must be globally unique and mean the same file everywhere -
a context-relative id from two missions would collide in the cache and
render the wrong art. Consequence: renaming a campaign/hub/mission dir
means rewriting the custom stems in its files (the same
rewrite-references pass as `destination_hub` values).

History: the pre-campaign-editor shape was `custom/<mission-dir>/<stem>`,
resolved by the LOADER against the loading file's dir but by the TEXTURE
STORE against a hardcoded persistent `missions/` root - internally
inconsistent (campaign-bundled art would have resolved dims at load and
rendered magenta), and hubs could not even construct their path (no
campaign segment). The campaign-editor slice 1c settle replaced both
channels with the one rule above.

### Custom-asset dimensions (warn + degrade, never reject)

Custom (mission-bundled) sprites follow the shipped asset structure:
**entity sprites exactly 512x640** (the fixed frame -
`types.entity_sprite_frame_*`), **decoration sprites whole multiples of
256 in both axes** (the view math chunks one 256px piece per bbox tile).
NO size cap - huge set-piece art is legal; sprites beyond 4096px in either
dimension get a device warning (WebGL2's guaranteed max-texture floor is
2048, but 4096+ is universal in practice), and the footprint editor's 8x8
draft grid is a UI gate, not a rejection.

The posture is the balance-bounds posture: custom content is UNTRUSTED,
so spec violations **warn + degrade, never reject, never crash**. The
editor must be able to open a broken mission to fix it (web users have no
external file access), and wrong dims are view-side only - the clamps are
pure functions of the file bytes, so replay/undo stay deterministic.

Load-side enforcement (landed - loaders.zig, surfaced via the same
`surfaceWarnings` popup as balance bounds):

- Decoration dims: unresolvable sprite (unknown shipped stem / missing or
  invalid mission PNG) → a 256x256 fallback (renders magenta); non-multiple
  dims → floored to the grid, minimum 1x1 tiles; >4096px → warned.
- Footprint clamps (footprint tiles dropped with warnings; an emptied or
  authored-empty footprint falls back to the sprite grid's bottom-left
  tile, the pick-commit default): out-of-bbox tiles, world tiles overlapping
  a level/hub tile, malformed `footprint` lines (skipped).
- Decoration layers: a dims mismatch vs the base warns and the layer is
  KEPT (renders cropped to the base grid - the view builds layer pieces
  from the base's source rects); an unresolvable layer sprite warns and
  stays (renders fallback).
- Entity sprites: the load warns (per base AND layer sprite in loadLevel's
  entity walk) - the entity still spawns.

The render-side gate (`types.customSpriteDimsPassGate`, applied at the
texture store's three decode sites - main textures, outline masks, and the
composite occlusion-inset blit): a custom sprite whose dims fail its
kind's spec is treated as MISSING everywhere - the magenta fallback draws,
and no mask traces art that isn't there. Non-custom ids are never gated
(shipped art is certified by the build-time metadata table; ui/, world/,
items/ follow their own conventions). No size gate - the >4096 warning is
advisory, and huge art renders wherever the device allows.

Editor-side enforcement (landed): the picker filter (slice 3 - the
mission-local tab offers only conforming art, with a visible hidden-count
note) + the pick-commit backstops (a custom sprite failing its spec
no-ops, nothing recorded - stale scans and crafted input can't mint a
guaranteed-magenta type) + the Revalidate art report (the success message
carries the violation list at the publish checkpoint; revalidation still
PASSES - violations degrade at runtime).

### Auth & the server seam (deferred)

- **Local-first always.** The editor saves a mission to the persistent
  `missions/` dir (zip or folder) - a complete, shareable artifact
  you can hand to anyone, post anywhere. No account, no server.
- **Online upload is optional and gated behind auth.** "Publish to the
  database" is a separate action requiring a token; the server validates
  (runs the validation replay, checks the content hash), assigns the stable
  versioned ID, and lists it. Authors get a profile page; missions get a
  discoverable entry.
- **Acquisition is symmetric:** online fetch (needs the server but NOT an
  account - browsing/downloading is anonymous) vs. manual import (zip/file,
  no server). A player never needs an account to PLAY custom missions, only
  to PUBLISH them.
- **Auth model (real accounts vs. device-identity) is UNDECIDED** - only
  affects the publish action, which is the last thing to build. The
  local-first story doesn't depend on it. Decide when the server seam lands.
- **Leaderboard integrity: the server REPLAYS, it never trusts claims.**
  Every leaderboard upload is a submitted validation replay; the server
  runs it through the same headless reconstruction the client uses for
  revalidation (`reconstructFromEventLogChecking` - the crown test is the
  prototype of this check), which gates each event on
  `validatePlayerAction` legality + natural-stack verification, and
  DERIVES the turns itself. Client-claimed times are never read.
- **Server-revalidation builds MUST be safe-mode (ReleaseSafe or
  tighter).** The whole validation machinery is panic-based
  (`rejectReplay` → `@panic`, the fail-fast unwrap policy); ReleaseFast
  turns those panics into UB, and undefined behavior on hostile input is
  not a rejection. Any binary that runs reconstruction/validation over
  untrusted logs - the future server, or any client build acting as one -
  is built ReleaseSafe or Debug, never ReleaseFast (PROJECTREVIEW Part 15,
  the security-posture headline).
- **TAS is valid BY DESIGN - no anti-TAS work, ever.** The game is
  turn-based, so any legal event log is in principle reproducible by a
  human player, one decision at a time. The leaderboard certifies
  "possible + reproducible", not "hand-played"; a hand-crafted legal
  log passing the check is not a cheat - it's a route.
- **Game-version upload policy is UNDECIDED (deferred to the server
  seam session)** - see TODO → Online Services for the open question and
  the tradeoffs.
- **Server component is out of scope for the single-file exe** - a separate
  backend. The client only needs a thin HTTP fetch/submit seam + an auth
  token stored in the persistent dir.

## Campaigns & the Campaign Editor

The campaign model + the second editor. The mission editor (see
Architecture → Level Editor) edits any mission; the campaign editor edits
the CAMPAIGN as a whole - map, hubs, edges. Hub editing lives INSIDE the
campaign editor (there is no standalone hub editor): a hub only makes
sense in its campaign's context (every exit needs the campaign's missions
to reference + its hubs as destinations), and the exit entry IS the edge
- the graph and the hub files are the same data, so they cannot drift.

### The graph model

- **Hubs are nodes; missions are unique EDGES (hub → hub).** One edge per
  mission (the one-edge rule: a mission is referenced by exactly ONE hub's
  exit; a mission enterable from two places is two missions or a redesign).
  The edge's from-end is the hub file it lives in; the mission ends at the
  edge's destination. Self-loops are legal (the prototype's camp→camp
  missions - destination = the from-hub; there is only one hub today).
- **Missions carry NO hub metadata.** mission.txt has no `start_hub` /
  `end_hub`: campaign missions are real geographical connections (the
  graph owns the edge), and custom missions (dreams) always end in the hub
  they were started from - the existing runtime fallback (`end_mission` →
  the entering hub when `start_mission.end_hub_id` is null) IS the dream
  story. `start_mission.end_hub_id` (the existing override seam) is
  populated by the hub-exit click path from the exit's `destination_hub`;
  the dreams-browser path leaves it null. The EVENT, not a completion-time
  lookup, is the replay-safe record of the edge. `level_count` is DERIVED
  (count the mission dir's `level_N.txt` files) - all three drift-prone
  authored duplicates die.

### Content identity (uuids everywhere; SUPERSEDES the names-as-references settle)

The slice-1 settle "references are NAMES, never indices" is REVERSED by
this one. Same two hard requirements (forward-reference; dangle LOUDLY,
never silently retarget), different answer: **every content kind -
mission, hub, campaign - is identified by a random v4 UUID authored in
its file content, and every reference between content files is a uuid.**

Why the reversal: the user-content-first model needs name collisions
legal everywhere (two campaigns can both have a "Village" hub; a custom
campaign can be named like the official one), and the player's own data
(clone records, discovered hubs, save positions) must survive author
renames. Names cannot carry that; uuids do it for free. What the names
settle loses - hand-readability of references, typing a name into a
hand-edited file - is accepted: copy-pasting a uuid is the authoring
cost, validation warnings pair uuids with display names for humans, and
the campaign editor (the primary authoring surface) picks from lists,
never asks for a uuid by hand.

- **The uuid and the content hash are DIFFERENT axes** (the mission
  convention, extended): the uuid is the CROSS-VERSION identity - random
  v4, minted WRITE-ONLY at the file's birth (the save path; never into
  GameState - `generateMissionUuid`'s replay rule), persistent across
  edits and renames; the content hash (the CHALLENGE identity - the
  two-axis doctrine + the artifact-scope rule live in Custom Missions &
  Online Services → Content identity) pins replays and leaderboard keys.
  Campaign hashing follows the same axes over the whole campaign
  artifact tree: the campaign VERSION hash (no exclusions - mission
  validation replays included; a re-validated mission IS a changed
  distributed artifact) is the server-side versioning key for uploaded
  campaigns; the campaign CONTENT hash (the same tree minus record
  files) is deferred until full campaign validation or campaign
  leaderboards need it.
- **Three attributes, cleanly separated**: uuid = identity (authored,
  immutable); dir name = storage (arbitrary, never referenced); display
  name = label (just a field, freely editable, may collide).
- **Minting policy**: rename-in-place NEVER re-mints (the uuid is the
  identity); an OFFICIAL-ORIGIN save DOES mint a fresh uuid (the fork
  rule - saving shipped content creates a new work; see The editor save
  model). Copy-at-pick campaign imports KEEP
  the uuid (settled): an import is the same authored work, and the
  records that key on the uuid - leaderboards, clone records,
  personal bests - persist across an import into a campaign. A
  duplicate-uuid import into a campaign already containing that
  mission is REFUSED (the picker grays out / annotates
  already-in-campaign missions; the editor never creates same-uuid
  siblings itself).

### Uuid→dir resolution (scan-based loading)

Loading resolves uuids to directories by SCANNING, never by convention:

- campaign load lists `campaigns/` (persistent) + the embedded official
  campaign, reads each `campaign.txt`'s `campaign_uuid`, and matches
  against the requested uuid; the winning campaign's `hubs/` +
  `missions/` scans build the hub + mission resolution tables the same
  way (uuid read from each hub.txt / mission.txt).
- **Any dir name loads** - the `<uuid>_<name>` convention is a
  save-side naming scheme for human browsability, never a load
  requirement. The official campaign's `main_campaign` dir (and any
  hand-named dir) loads by its uuid.
- **Duplicate uuids across dirs** (manual file copying, hand edits):
  resolve **latest-updated wins** - the MAX mtime across the
  folder's files (the mission browser's recency convention,
  `scanMissionFolder.max_mtime_ns`), name-ascending breaking exact ties
  (copied folders carry identical mtimes - deterministic under all
  inputs). **Tier shadowing is not duplication**: a persistent
  candidate makes the embedded original with the same uuid UNREACHABLE
  (FileSource's persistent-first read order), so cross-tier repeats
  resolve to the persistent copy silently - the deliberate
  hand-installed override path (the ONLY source of shadow pairs: the
  editors' saves never shadow official content, they fork - see The
  editor save model). The duplicate warning is SAME-TIER
  only: two persistent dirs with one uuid (a hand fork), or two
  embedded dirs (a shipped-content collision). Either way uuid
  resolution and the read order can never disagree, and identity-keyed
  records stay coherent by definition (same uuid = same identity:
  either copy's completion updates the same clone). A lazy
  content-hash comparison (missions; campaigns when hashing lands)
  distinguishes redundant copies (same hash - silent-ish) from
  diverged versions (different hash - the warning says so) in the
  warning text. A same-tier duplicate is hand-made content; the split
  is deleting one of the copies (the warning's advice) - the editor
  never creates duplicates or shadows itself.
- **Replay purity**: scans are LISTINGS, not reconstruction reads, so
  the recorded events carry RESOLVED payloads (the mission-browser
  pattern): push sites resolve live (scan at click / new-game time) and
  events carry both the uuid and the resolved dir (`start_hub` gains
  `campaign_dir` + `campaign_uuid` + `hub_dir` + `hub_uuid`);
  replay reads the recorded paths through the cache and never
  re-scans. `PlayerData` references identity only (`current_campaign_uuid`,
  `current_hub` as uuid) - never storage.

### The editor save model (in-place identity, official-origin forks)

Name is just a field: the editor's metadata sidebar edits it, save
persists it into the content file, and nothing else happens - no
reference rewrites (references are uuids), no new dir, no re-mint. This
dissolves the deferred hub-rename question ("rewrite references vs
no rename in v1"): rename is free, for all three content kinds.

- **The save target is the content's existing dir** when the identity
  exists AND the content is persistent (the opened campaign's
  campaign.txt / the opened mission's mission.txt reachable in the
  persistent tier - `FileSource.persistentFileExists`): a rename-save
  writes the same files with a new `name` field, same dir, same uuid. A
  NEW dir is created when identity is genuinely new - a fresh
  mission/hub/campaign's first save (mint) or an OFFICIAL-ORIGIN fork
  (next bullet).
- **Saving official content FORKS** (the identity model's one rule
  everywhere): state identity naming content that exists ONLY embedded
  is ignored at save - the campaign mints a fresh uuid +
  `campaigns/<uuid>_<name>` dir, every hub + mission mints fresh
  identity too (a fork is fully new identity: no shared clone records
  or leaderboard keys with the originals), and a WHOLE-DIR CARRY
  re-creates the opened content's files under the fork (levels,
  player.txt, custom art, the campaign root's background PNG) - the
  fresh config writes land on top. The mission editor holds the same
  rule over its opened mission: an official mission saves as a fresh
  standalone identity in `missions/` (the editor state holds the
  content, so no carry is needed). The fork identity is memoized like
  every mint (stable across the session's saves); a session that saves
  nothing writes nothing. The import path mints the fork EARLY
  (`campaignImportDir`) so an official-origin campaign's imports copy
  into the fork-to-be dir (a dir without a readable campaign.txt never
  lists, so the half-born fork stays invisible until saved); the
  background scan + every other campaign-dir consumer read the
  EFFECTIVE dir (`effectiveCampaignDir` - the memo's fork, else the
  opened dir). Net effect: the only persistent shadow of official
  content is one installed by hand.
- **Cosmetic dir tidy on save**: if the dir's name doesn't match
  `<uuid>_<current_name>` and the target name is free, the dir is
  renamed in passing (after the config writes succeed - content is the
  truth, the rename is cosmetics). If the target is taken - including
  by a duplicate-uuid sibling - keep the old dir name and warn with
  the duplicate warning shape. Keeps `missions/` / `campaigns/`
  self-describing without ever creating identical-uuid dirs.
- **Custom-art stems ride the dir**: `custom/...` ids embed the content
  dir, so a dir rename rewrites the stems in the content's own files
  (the mission writer's existing stem-rewrite machinery; it now fixes
  in-place too). Campaign-level references are uuids - unaffected.
- **FileSource gains a `renameDir` seam** (native: rename; web's
  in-memory mount: the same operation). Shared by all three kinds.

### File formats (each change bumps its per-type file_format_version)

- **campaign.txt owns the graph** (v5): `background` (a
  bare stem naming a PNG in the campaign's OWN directory - official and
  custom campaigns author it identically; the loader mints it into the
  content-addressed sprite id at load, so the render side resolves it
  through the standard custom-asset rule) + a `Hubs` section, one group
  per hub (`hub_uuid` + `position`) + a `Missions` section, one group
  per mission - THE first-class edge table: `mission_uuid` + optional
  `start_hub`/`destination_hub` (hub uuids) + optional `direction` +
  the optional ghost positions (`start_position`/`destination_position`,
  the frozen map positions of deleted ends - the editor's orphan
  rendering). A mission in ANY authored state (markerless, dangling,
  orphaned, self-loop) is one group carrying its whole edge data: the
  save/load round trip is TOTAL over campaign-editor-reachable state,
  and a markerless mission is a VALIDATION finding (3f), never a save
  blocker. Subsumes v4's Orphans section (an unwired mission is a
  Missions group with no `start_hub`). Both sides read it: the editor
  rebuilds its authored graph from it, the runtime builds the edge
  table from it (the exit-marker join in hub.txt supplies startability
  - see the hub.txt bullet). Positions live HERE, not in hub.txt -
  the map is campaign-level data: moving a hub edits one file, and the
  world map loads the whole graph geometry in one read without touching
  every hub file. The coordinate model: see The map coordinate model
  below.
- **Load-time graph integrity checks** (landed -
  `loaders.checkCampaignGraph`, called from `loadCampaignAndPushHub`,
  warn-only through the standard surfaceWarnings popup; the same checks
  ride the campaign editor's file-level Validate - one shared standard):
  start hub not placed; a placed hub with no readable/parsable hub.txt;
  every mission fully wired - no dangling stub (destination unset), no
  destination naming an unplaced hub, no orphan (a Missions entry wired
  to no placed hub), no markerless mission (unstartable - rendered,
  not enterable); a Missions entry whose uuid resolves to no mission
  dir; unreachable hubs (BFS from the start hub over the Missions
  edges). The finalized-campaign doctrine: stubs, orphans, and
  markerless missions are editor-INTERMEDIATE state - honest to carry
  mid-editing, a finding in a finished campaign. The checks read
  campaign.txt/hub + mission
  files through `file_source` directly, NOT the reconstruction cache:
  warnings apply no bytes to state (surfaceWarnings is !replaying-gated,
  advisory-only), so replay purity is unaffected.
- **hub.txt** (v3 landed; v4 adds the uuid sweep; v5 - the campaign-format
  settle - reduces the Exits entries to pure tile materialization; v6 -
  the hub editor - will add the three gradient keys, mirroring level
  Metadata): `Exits` entries are pure TILE MATERIALIZATION -
  `character_code` + `mission_uuid` (the marker's grid cell + the
  mission it starts). Edge data (destination, direction) lives in
  campaign.txt's Missions section, NOT here: a marker is the playable
  materialization of an edge, and an edge with no marker is
  representable + rendered, just not startable (a validation finding,
  never a save blocker - see The map surface). Runtime consumers that
  used to read an exit's destination/direction resolve through the
  campaign's edge table by mission_uuid instead. The `NPCs` section
  becomes `character_code` + `npc_type`. Hubs bundle their own custom
  decoration art - `hubs/<hub>/` gains the art folder, custom stems
  content-addressed as `custom/campaigns/<campaign>/hubs/<hub>/<stem>`
  (the ONE rule - Custom Missions & Online Services → Custom-asset paths).
  The official campaign ships no custom art, but fully custom campaigns
  are possible and self-contained.
- **NPCs are NOT entities** (the old `NPC { entity }` was stale scaffolding):
  `NPC = { npc_type, position }` - the sprite DERIVES from the type (the
  two shipped `assets/npcs/` files; `NpcType = { gear_upgrader,
  dream_guide }` - the whole cast for the foreseeable future). Blocking
  (NPC tiles aren't walkable; clicks on them fire nothing) needs only the
  position. The hub PLAYER stays an Entity. `interact_with_npc` (still a
  stub) routes on the type when it lands - the gear-upgrading vendor is
  simply a `gear_upgrader` NPC placed in a hub (no extra hub-format
  marker); `dream_guide` is the dreams-browser entry (already designed -
  Custom Missions & Online Services → Browser).
- **mission.txt drops `start_hub` + `end_hub` + `level_count`** (v3,
  landed): the writer stops emitting them; the loader warns + drops old
  keys. `Mission.end_hub` survives as a pure runtime channel populated
  only by the `start_mission` override (the exit-click path passes the
  exit's `destination_hub`; restarts pass the live value through; the
  overlay's re-run derives it from the hub's exit for the mission) - null
  means the entering-hub fallback. The level count DERIVES at
  start_mission/start_validation/open-editor via a reconstruction-sound
  probe (`countMissionLevelsCached` over
  `readReconstructionFileOptional`): read `level_1..level_N` through the
  cache until one is absent; the absent file caches an empty-bytes
  known-absent MARKER, so replay re-derives the same count even if level
  files appear on disk mid-session (a plain listing would drift - the
  reconstruction-cache motivating case). The non-replay consumers
  (mission browser scan, content hash) derive the same rule from
  file_source listings directly; the count rule everywhere: the largest
  N with level_1..level_N all present (a gap truncates).

### Campaign content paths (content-root-relative, one shape)

Every campaign-content path - built at the three handler sites
(`loadCampaignAndPushHub`'s campaign.txt, `start_hub`'s hub.txt, the
exit-click mission path) and carried in events (`start_mission.
mission_path`, `open_editor.mission_path`, the browser's
`MissionEntry.path`) - is **content-root-relative**:
`campaigns/<campaign>/...`, never `data/campaigns/...`. The `data/`
prefix is EMBEDDED-MAP
ADDRESSING, not part of a content path: the official campaign's files
are embedded under `data/campaigns/...` keys, and `FileSource.readFile`
bridges the two (persistent `campaigns/...` first - custom campaigns live
there at the same shape - then embedded as-is, then embedded under the
`data/` prefix; `readEmbeddedFile` mirrors the same two embedded tiers).
One shape means official and custom campaigns address identically
(reported as a review rider, PROJECTREVIEW Part 5: the hardcoded
`data/campaigns/...` builds would never have resolved a custom campaign).
Compat: a `data/`-prefixed path still resolves through the embedded
as-is tier, so session logs recorded before the re-shape reconstruct
unchanged. Related: Custom-asset paths (the `custom/campaigns/<c>/...`
stem rule) is the same convention on the sprite-id side.

### The map coordinate model

Hub positions are **center-offset integers**: `position 0 0` is the
map's center - the same point the background anchors to - and values are
pixel offsets from it, unbounded in every direction (negative values are
normal; a hub outside the map view's default framing is reachable by
zooming out - the levels-are-infinite philosophy, no clamps, no
validation). The hub icon renders CENTERED on its position.

The background is embedded **centered on the origin**: a 1000×1000 image
is a small island in the middle of the map, whatever its size - the
stored positions never depend on the background's dimensions, so
re-skinning or resizing the art moves nothing.

The **default map framing** is a VIEW constant, never campaign data: the
map view (buildWorldMap + the campaign editor view) opens framed on a
3840×2160 region centered on the origin. **Fixed framing in v1** (see
Edge geometry): no zoom/pan yet - the builder keeps one transform slot
so zoom can land later without a rewrite (zoom would then behave
exactly like in-game zoom, the same camera model over the same space).
If 4k proves the wrong default, it is a one-constant change - nothing
stored depends on it.

The start hub's position is ordinary authored data - no rule places it
at the center. The official campaign currently places it at `0 0`
(sitting on the background's center); that placement moves with the art
whenever the real map lands.

### Discovery + travel (the world map's gameplay)

- **Discovered = visited, discovered ON ARRIVAL.** The `start_hub`
  handler appends the arrived hub's uuid to the active campaign's group
  (idempotent) - ONE rule composes everything: new game (arrival at the
  start hub - no seeding code anywhere), mission completion (the
  destination hub), backtrack travel, cross-campaign entry, mission-
  from-map (the edge's start hub). Undo to before an arrival
  un-discovers - correct timeline semantics.
- **The discovered set is GROUPED BY CAMPAIGN on PlayerData** (uuid-keyed
  groups: `{campaign_uuid, hub_uuids}`): hubs are only a thing inside
  campaigns, a scoped lookup is exactly what the map render needs, and
  groups for uninstalled campaigns are KEPT (the player may switch
  back). Persisted in saves. A fresh campaign needs no seeding - a
  campaign's start hub is ALWAYS travel-legal (discovered-or-start),
  which is also what makes the fresh view show one live hub and its
  edges with everything else dimmed.
- **Map travel is BACKTRACKING only** - jump to any DISCOVERED hub; forward
  movement is playing edges (the core loop: missions are the connections,
  and the map must not skip them). Every campaign's START hub is always
  act-legal EVEN WHEN the campaign was never entered (no discovered group
  yet) - which is what makes entering a newly added campaign possible at
  all; the legality read resolves the start hub from the campaign's
  campaign.txt through the RECONSTRUCTION cache for other campaigns (the
  active campaign's graph is pure state).
- **Map mission-entry is deliberately EQUIVALENT to the exit tile**: an
  edge is clickable when its start hub is discovered, and starting it is
  the same as standing on the exit in the start hub. The world map is a
  navigation shortcut for players who want it - never a requirement. The
  entry is FROM the edge's start hub: `start_mission.enter_hub_id` sets
  `current_hub` on the way in (a pure PlayerData write - NOT a hub
  transition, which would clear the event stack and eat the queued
  entry), so abandoning the entered mission returns there.
- **The map is ALWAYS navigable** - from a hub or mid-mission alike.
  Acting on it mid-mission rides the existing abandon cascade
  (`end_level{.exit_mission, suppress_return_hub}` → the queued
  arrival/entry beneath): pickups are kept (the `end_level` sync
  invariant - `build_data_from_player` before any level discard; tested
  in `handler_tests_autosave`), the run earns no clone (the clone is the
  record of COMPLETED runs). The suppress flag exists because
  `transitionScreen` clears the event stack - the exit's own
  `end_mission → start_hub` return would eat the map action's queued
  arrival, so the map-acting orchestrators queue their REAL arrival
  (start_hub / start_mission) beneath the end_level and suppress the
  default return.
- **The acting orchestrators** (`player_travel_to_hub`,
  `player_start_mission_from_map`) carry the click-time RESOLVED payload
  (hub uuid; mission path + end hub + start hub from the edge table) +
  the campaign identity when acting on a VIEWED campaign ≠ the active
  one (null = active). Legality is validated per-event in
  `validatePlayerAction` (map open + level/hub screen +
  discovered-or-start).
- **Rendering: the simple mirror first** - the world map renders ALL hubs
  + edges (the exact campaign-editor view) with undiscovered hubs /
  unavailable missions DIMMED. Fog-of-war hiding is a future refinement
  if the simple mirror proves too revealing (see TODO).
- One data model, two renderers: `buildWorldMap` renders exactly what the
  campaign editor renders (background + hub positions + edges) - the
  read surface and the edit surface share the graph-derivation + layout
  math.
- Future surface (see TODO): a pre-mission briefing overlay (leaderboards,
  current clone info + medal achieved) before ANY mission start - map
  edge, exit tile, re-run alike.

### Campaign switching (the viewing model)

Only one campaign is ACTIVE at a time (the one whose world the player is
in - `current_campaign_uuid` on PlayerData), but the player can VIEW any
installed campaign's map at any time and SWITCH by acting on it:

- **Viewing ≠ state.** The world map's top-left campaign button (the
  viewed campaign's name, no prefix) opens the CAMPAIGN BROWSER - a
  full-screen stackable overlay (`UiSurfaceId.campaign_browser`) with
  the editor browser's split (Your Campaigns / Official tabs, the
  shared list-browser body in browsers.zig). The tabs list
  `listCampaigns` (the persistent `campaigns/` scan) +
  `listOfficialCampaigns` (the embedded scan) - the `listMissions`
  pattern, scan-on-open, SessionState-held. Picking a row derives that
  campaign's graph (`shared.loadCampaignGraph` - the same loader chain
  as the active campaign's load, through plain reads) into the
  session-scoped cache (`SessionState.viewed_campaign`; picking the
  ACTIVE campaign clears it - the map falls back to the live GameState
  campaign) and closes the browser via the recorded surface toggle;
  the pick itself is never recorded (replay-irrelevant, the
  `editor_local_missions` pattern). Recorded clicks (2d acting) carry
  fully resolved payloads (campaign uuid + dir, hub uuid + dir,
  mission path, end destination) - the mission-browser-row precedent;
  legality never reads the cache.
- **The active campaign switches as a side effect of ACTING on another
  campaign's map.** The acting orchestrators carry the click-resolved
  campaign identity (dir + uuid) when the map is viewing another
  campaign, and the cascade pushes `install_campaign` beneath the real
  arrival/entry: a machinery event that loads the target graph through
  reconstruction reads (the `load_save` / `start_level` precedent -
  handlers already do recorded reads; the graph load is
  `shared.installCampaignGraph`, shared with the continue/load-save
  path), swaps `current.campaign`, and updates the PlayerData identity
  fields. NO screen transition - the install rides INSIDE the cascade
  (a `transitionScreen` would clear the event stack and eat the queued
  arrival; the same constraint that shaped the mission-entry path).
  The arrival itself then proceeds through the ordinary `start_hub`
  (installs the hub, sets `current_hub` - which IS the last-visited
  hub - and discovers into the NEW campaign's group), and a map mission
  entry sets the edge's start hub as `current_hub` via
  `start_mission.enter_hub_id` on the way in. No separate resume
  bookkeeping: ONE `last_hub` = `current_hub`, exactly one per player.
- PlayerData (gear, materials, clones) travels across switches - the
  player IS the save; campaigns are worlds they enter. The save file is
  untouched by switching (no autosave backup needed - nothing is
  overwritten).
- The future new-game campaign picker (choose a start campaign) and the
  speedrun seed (a start option that marks ALL of the just-loaded
  campaign's placed hubs discovered - RUNTIME-derived from the graph,
  never an authored maxed save) share `listCampaigns` and this machinery.

### Edge geometry (loops, dangling stubs, parallels)

Edges have no position of their own - they derive geometry from anchors.
A two-hub edge interpolates them (well-defined). A SELF-LOOP and a
DANGLING edge (destination not placed yet) are the two degenerate
one-anchor cases, and that is exactly when the author supplies the
missing information:

- **`direction <degrees>`** on the mission's Missions entry in
  campaign.txt - compass
  convention (0 = north, clockwise), integer, PER-EDGE (a hub's four
  self-loops need four distinct click targets, so collision control is
  per-edge granularity). It positions both degenerate cases: the
  self-loop's departure angle AND the dangling stub's bearing.
- **Rendering: cubic beziers.** Self-loop = the four points
  `{hub, hub + d·L + n·w, hub + d·L - n·w, hub}` (d = direction unit
  vector, n = perpendicular; L, w = fixed view constants in v1 - style
  consistency; an authored length override is a later dial) - a narrow
  elliptical teardrop. Straight edges are the degenerate bezier (all
  controls on the segment). One `arrow` UiElement variant (two endpoints
  + two control points + width + color; ONE deterministic sampling
  helper - `sampleArrow` in element.zig - feeds both hit-testing and
  the baked-arrow rasterizer, which is the distance-to-SAME-polyline
  test run per pixel, so the drawn edge and its hit region cannot
  disagree - see The map surface);
- **Defaults when unauthored: auto-spread.** The UNAUTHORED exits
  sharing a hub space their directions evenly among themselves over the
  full circle (four unauthored camp loops land at 90° spacing;
  authored ones sit where placed - no gap bookkeeping); parallel straight
  edges between the same hub pair spread perpendicular by exit index.
  Cosmetic default, no warning (the warn surface is for correctness, not
  style); the author overrides per-exit for expression. One rule
  everywhere: the runtime's `deriveCampaignEdges` and the campaign
  editor's rendering share it, so a saved unauthored exit renders the
  same in-game as in-editor.
- **The map view is FIXED in v1**: the 3840×2160 default framing (a view
  constant - see The map coordinate model) with no zoom/pan; the builder
  keeps one transform slot so zoom can land later without a rewrite.

### The map surface (the world-map overlay's build)

The world-map overlay (a full-screen overlay, `toggle_world_map` - the
surface plumbing predates the view) renders `buildWorldMap`; the campaign
editor's view (slice 3) renders the same graph geometry through its own
builder - one data model, two renderers (see Discovery + travel). The
shared implementation is `src/ui/campaign_geometry.zig` (`mapToScreen` +
`deriveEdgeGeometry` + the view constants): each renderer resolves its
graph into the endpoint class + parallel spread and derives through it.

- **The active campaign's map is a PURE STATE read.** The load scan
derives the campaign's EDGE TABLE into `Campaign` - every hub's exits
(from-uuid, destination-uuid, mission uuid + the scan-resolved dir +
name, the EFFECTIVE direction: authored, else the auto-spread default
by exit index - see Edge geometry) - plus each hub's DISPLAY NAME
(denormalized from hub.txt, the mission-table precedent). The scan
already reads every hub.txt for uuid resolution, so capturing exits +
names is an extension of an existing read, not a new one. The map view,
the dim-undiscovered mirror, and (2d) acting legality + resolved event
payloads read STATE; `view()` stays file-free.
- **Viewing another campaign goes through the session-scoped graph
  cache** (`SessionState.viewed_campaign`; the `editor_local_missions`
  pattern: idle-input acquisition, SessionState-held, replay-irrelevant):
  picking a campaign in the browser derives ITS graph with the same
  loader chain into the cache. The browser's tabs list `listCampaigns`
  (the persistent scan) + `listOfficialCampaigns` (the embedded scan -
  the `listMissions` pattern); a picker that cannot see persistent
custom campaigns is a lie, so both shipped with the browser. Legality
  never reads the cache (see Campaign switching).
- **Clickability rides the spriteless-Button seam.** The visual
elements - hub icons (`image` or a filled shape) + `arrow` edges -
are decorative (`blocks_input = false`); a spriteless `button`
(`sprite_id = null`) overlays each clickable target carrying the
action + payload + tooltip. Hubs: `travel_to_map_hub` + the hub index
(`map_hub` payload), emitted only for LIT hubs (discovered-or-start =
travel legality - what the map lights is what is clickable). Edges:
`start_mission_from_map_edge` + the edge index (`map_edge` payload),
emitted only for LIT edges with a resolvable mission, BEFORE the stroke
pair (painter order - the hover rim renders beneath the art). A
MARKERLESS edge (started + destination but no exit marker in its
start hub - the edge table's `exit_index` is null) renders the stroke
WITHOUT a button: the map renders as much of the graph as the data
defines, but mission entry stays equivalent to the exit tile (no
marker, no entry - the 3f validation finding closes the loop). The
button's `hit_arrow` carries the DRAWN ARROW's geometry at its
outline-inclusive width (black outline + inner stroke): the hit region (sampled polyline), the tooltip
bounds (`arrowBounds` - the bbox incl. the chevron, so the tooltip
frames the whole arrow), and the hover highlight (the baked arrow's
OUTER outline mask - the same disk-dilation machinery as every sprite
hover halo, drawn as the arrow's OWN rotated quad + the highlight tint,
stripe-treated; the rim sits OUTSIDE the black outline, which is part
of the arrow art, the sprite-backed convention - see the baked-arrow
section below) all derive from the one arrow, so they cannot
disagree. No new element contract for input.
- **One sampling function + one baked texture per shape.** `sampleArrow`
in element.zig is the single deterministic bezier sampler (fixed
segment count in v1): hit-testing is distance-to-polyline against its
samples, and the DRAWN edge is the same distance test rasterized once
per shape - campaign_geometry classifies an arrow into a canonical
east-pointing arrow (a FIT, not a shape enumeration: the bucketed
reconstruction must stay within an 8px tolerance of the arrow's own
samples + chevron arms, else the arrow falls back to the per-segment
draw), bakes the black outline + WHITE inner stroke into one texture
(the render seam's `arrow_cache`, the outline/inset-mask pattern), and
every edge of that shape draws ONE rotated textured quad - tinted so
the white inner becomes the edge color while black stays black, dim /
ghost alpha fading the whole arrow uniformly. Straight edges key on 8px
length + bow buckets (parallel siblings bow apart - the spread offset
is a cache axis, not a straight-line assumption); the teardrop and the
stub are fixed shapes, one entry each. Lengths clamp to the platform
texture limit (`maxBakedArrowLength`). The builders emit ONE decorative
arrow per edge at the outline-inclusive width carrying color + dim
state. The hover/selected rim rides the SAME bake: the arrow canvas
pads past an `outline_thickness` halo band, and the rim is the
rasterized silhouette dilated OUTER at that width (the render seam's
`arrow_outline_cache`, lazily generated per hovered shape - the third
caller of the disk-dilation pass shared with the sprite masks), drawn
as the arrow's own quad through the outline-stripe scope. The smooth
rolling-disk outer edge replaced the old widened per-segment rim,
whose bevel-joined, unantialiased quads read jagged against the baked
arrow's anti-aliased edge; the per-segment `drawLineEx` path survives
as the fallback for BOTH the arrow and its rim (arrows outside the
bake families, failed bakes/masks). Headless-testable
end to end: the classifier + rasterizer are pure, in campaign_geometry.
- **Dimming**: undiscovered hubs dim + edges whose start hub is
undiscovered dim (the clickable rule is exactly start-hub
discovered); a never-entered campaign's view shows the start hub +
its edges lit (discovered-or-start covers the view too - no
seeding). See Discovery + travel.
- **Framing**: the fixed 3840x2160 view constant, letterbox-fit to
the screen (The map coordinate model). One transform slot for later
zoom.
- **Hub icon art**: none exists yet - the magenta missing-art
fallback + an art_report line (the map-background placeholder
posture).

### The editor-state split (settled: a parallel CampaignEditor)

Where the campaign editor's state lives, settled by the pre-slice-3
spike against the real Editor code: a **parallel `campaign_editor`
field on GameState (a `?CampaignEditor`) + a `campaign_editor` Screen
variant** - NOT the lean (a campaign payload riding inside `Editor`).

Why the parallel shape wins:

- **The mission hand-off needs both states LIVE simultaneously**
  (click an edge → the mission editor in campaign context; the campaign
  graph survives; return to the campaign graph from there). A strict
  mission/campaign content union cannot represent that state, so the
  lean degrades to a sibling payload inside Editor anyway - at which
  point it is the parallel option with worse field placement.
- **Editor and its ~50-event family are mission-shaped.** Replay
  validates each editor event against `screen == .editor` +
  `editor != null`; a campaign payload inside Editor would force an
  audit of every existing validation (is this event legal on the
  campaign surface?) for zero structural gain. Parallel keeps the
  mission editor untouched and gives campaign-editor events their own
  screen-scoped checks - the established per-event pattern.
- **The mandated hub-editor reuse is CODE reuse, not state reuse.**
  The planners + selection algebra (editor/planning.zig) operate on a
  level-shaped grid + placements + `Selectable`; the hub payload
  embeds an EditorLevel-shaped grid and the planners get extracted to
  take the grid directly - required under either option, decided by
  neither. The state shape buys nothing here.
- **The campaign map surface shares nothing with the Editor spine**
  (free-drag float hubs, no grid, no selection algebra, no clamp
  bounds, no playtest mode). The spine flags only become meaningful
  again in the hub drill-in - which is level-shaped anyway.

Consequences:

- **Screens + scopes**: the `campaign_editor` screen's scope is
  `{ campaign_editor }` (no `.level` interplay - the campaign editor
  has no playtest); the `editor` screen's scope GAINS
  `campaign_editor` so the scope-drop rule (the transition-time
  auto-null) keeps the campaign alive across the mission hand-off
  transition, and dropping back to the campaign screen nulls the
  mission Editor the same way.
- **CampaignEditor edits an AUTHORED, editable graph** (the
  EditorLevel-vs-runtime-Level precedent): hub list with positions,
  exits, background stem - not the load-derived Campaign type. Save
  writes campaign.txt + the hub files.
- **`Selectable` gains hub-surface arms** (NPC placement, exit
  placement - shaped at the hub-editor slice); the union stays
  per-surface by construction under the split.
- **The undo timeline is shared either way** (the history snapshots
  the whole GameState), so undo steps across the campaign ↔ mission
  hand-off under both shapes - a non-differentiator.
- The mission-editor campaign-context question (what differs beyond
  the return path) remains open at the hand-off slice, now on a
  concrete substrate: a campaign-context field on the mission payload.

### The campaign editor

- **The campaign view is the single surface** (no hub tabs): the background
  image, hubs placed FREELY (no grid - float positions) and draggable,
  mission edges rendered between well-defined hub pairs, dangling ends
  tolerated (rendered differently). Click a HUB → drill into the hub
  editor; click an EDGE → hand off to the mission editor for that
  mission.
- **The hub editor (the drill-in view)** reuses the mission editor's
  viewport machinery - camera/clamp, selection algebra, marquee,
  move-drag, the tile tool, decoration tools + palette, player spawn -
  MINUS the entity/item/level machinery (no entity tooling, no player.txt,
  no level tabs, no hub playtest: nothing to do in a hub until NPC
  interaction lands). New tools: mission-exit placement + NPC placement.
  The settled surface design (tools, inspectors, palette scope, save
  granularity): see The hub editor surface. Custom decorations are
  authorable (the bundled
  hub art above).
- **Edge creation lives on the CAMPAIGN MAP, not in the hub editor**
  (supersedes the original exit-inspector mission choices): the mission
  tool creates a mission + its edge in one gesture; the mission
  inspector IMPORTS (copy-at-pick - the campaign owns a snapshot; the
  campaign dir is always the source of truth - uuid KEPT, duplicate
  imports refused; see The editor save model) and RE-ATTACHES
  start/end. The hub editor only POSITIONS exit markers for missions
  already starting at its hub (see The hub editor surface). A
  mission's destination is picked on the map (click an end hub, or
  re-attach) or left empty (the dangling stub - editor-intermediate
  state, tolerated mid-editing; a campaign-validation finding: a
  finalized campaign wires every mission's end).
  All picks are by list or map click, never a uuid by hand.
- **Saving keeps the campaign dir self-contained**: campaign.txt + map +
  `hubs/` (+ bundled art) + `missions/` (+ their art). The mission
  STORE-zip pattern extends to campaign export at the online-services
  seam.
- **The editor browser gains the Campaign kind tab** (a kind appears as a
  tab only when its editor lands) - lists/scans `campaigns/` in the
  persistent dir + a New Campaign button (the New-derives-from-active-kind
  rule).
- **The mission editor in campaign context** (the edge-click hand-off)
  knows its campaign and returns via a WORLD-MAP BUTTON (a top-bar
  button shown only while campaign context is active; returns to the
  campaign graph - see The campaign editor surface). The ONLY other
  difference is the SAVE TARGET: ctrl+S (and the options-menu Save)
  writes the mission into the CAMPAIGN'S `missions/` dir instead of
  the standalone `missions/` (the per-screen save granularity - see
  The hub editor surface). Everything else is IDENTICAL to a
  standalone mission session: EXPORT (the mission STORE-zip)
  works just the same, as do Test/Validate and the rest of the
  editor. Settled - nothing else differs.

### The campaign editor surface (settled requirements)

The slice-3 interaction design. The state shape is settled separately
(see The editor-state split); this section is what the surface DOES.

- **The authored graph is MISSION-CENTRIC.** CampaignEditor holds hubs
  (uuid, dir, name, position) + mission entries - identity (the uuid
  for on-disk missions, an in-editor handle for unsaved ones), name,
  start hub?, destination hub?, direction, ghost positions (see
  Deletion below). campaign.txt's Missions section is the ON-DISK EDGE
  TABLE (one group per mission, full edge data); hub.txt's Exits
  sections are the MARKER projection (one entry per placed exit
  marker: its tile + the mission). Loading a campaign into the editor
  runs the inverse projection (Missions groups → mission entries;
  hub exits → marker placements). The one-edge rule becomes
  STRUCTURAL: a mission is one entry, so it cannot be referenced by
  two hubs -
  nothing to enforce.
- **Unsaved missions: in-editor handles + session-scoped minting.** A
  fresh mission has no uuid until save (the write-only mint rule);
  the authored graph references it by a deterministic in-editor handle
  with a temp dir anchor under the campaign's `missions/` (the
  fresh-mission `missions/New Mission` precedent, generalized). Save
  resolves handles → minted uuids through a session-scoped memo (the
  `editor_saved_mission` precedent, extended to a table); nothing
  random ever enters GameState.
- **Layout mirrors the mission editor**: tool palette (bottom),
  inspector (left), metadata sidebar (right), Save + Validate primary
  actions (top-right; ctrl+S saves the FULL campaign - the per-screen
  granularity: see The hub editor surface). No Test/Playtest - there is
  nothing to play in a campaign.
- **Tools** (the active-tool model):
  - select: single-select v1 (multi-select + multi-reposition of hubs
    is future polish - TODO); click-select + drag-move commits one
    position event on release (the preview is transient drag state).
    Re-angling self-loops/dangling stubs is a direction field in the
    mission inspector (drag-the-tip polish can ride later - both
    write the same event).
  - hub: a click on empty canvas places a hub at that point (the whole
    4k canvas is placeable - the background is art, not a bounds); a
    click landing on an existing hub SELECTS it, never displaces.
  - mission: click a start hub → the arrow follows the cursor → click
    an end hub → places the mission + its exit entry in one gesture.
    Clicking the same hub twice = a self-loop. Clicking empty space or
    a clean right-click cancels the draw; a right-drag pans during a
    draw.
- **The hub inspector** (selected hub, or the last placed object when
  it is a hub - the auto-open-on-new-type precedent): editable name
  (rename is free); the campaign START-HUB toggle - radio semantics by
  construction (campaign.txt's one `start_hub`): toggling a hub
  untoggles all others, untoggling the current start hub is vetoed
  with a message, deleting the start hub is vetoed with a message
  (toggle another first); Open Hub Editor (the slice-4 drill-in).
- **The mission inspector** (selected edge/mission, or the last placed
  object when it is a mission): editable name; Open Mission Editor
  (the slice-5 hand-off); Import from the player's local missions
  (copy-at-pick - the uuid is kept, duplicate-uuid imports refused;
  see The editor save model); start/end RE-ATTACH (click the button,
  then click a hub - re-wiring, for orphans and wired missions alike;
  moving the start re-homes the exit entry, pure data under the
  mission-centric model); the direction field for self-loops and
  dangling stubs.
- **The metadata sidebar**: editable campaign name (rename is free;
  cosmetic dir tidy on save) + the BACKGROUND picker - lists the PNG
  stems in the campaign's own directory (the sprite picker's
  mission-local scan precedent) plus a none option. No import-image
  flow in v1: native authors drop files into the campaign dir; an
  import can ride the zip-import machinery later if wanted.
- **Deletion: right-click; orphan, never cascade.** Deleting a HUB
  removes the hub only - its missions become ORPHANS, frozen in
  place: the deletion event stores the hub's position into each
  touching mission's ghost slot (`orphan_start_position` /
  `orphan_destination_position`), and rendering uses the live hub
  position where an end survives, the ghost position where it does
  not. A fully-orphaned mission renders as the complete edge floating
  where it was, in a distinct ghosted style - selectable, salvageable
  (re-attach), deletable. When deleting a hub turns a straight edge
  into an end-orphan, the new stub's direction inherits the deleted
  edge's terminal bearing (deterministic, replay-safe). Deleting a
  MISSION removes it outright. Files are removed only at SAVE, and
  only for explicitly deleted things - orphaned mission files are
  always kept (keeping them is the point of orphans). The FileSource
  delete seam is DIRECTORY-level, never per-file: readFile's per-file
  persistent→embedded fallback would resurrect a deleted hub.txt from
  the embedded campaign while its dir lingered.
- **Unwired missions persist in campaign.txt's Missions section (v5)**:
  a mission group with no `start_hub` + the ghost positions. Honest
  campaign data - these mission files belong to this campaign but are
  not wired to the graph - read/written by the editor's save projection,
  ignored by the runtime edge table (orphans are not gameplay).
  Validation findings, machine-checkable: an orphan whose uuid resolves
  to no `missions/` dir (files deleted by hand); a mission started at a
  hub with no exit marker placed there (unstartable - the 3f finding);
  more than one marker naming one mission (hand-edit).
- **Default templates**: a new hub = a SINGLE tile with the player
  spawn ('!') - empty exits/NPCs, name "New Hub", uuid minted at save
  (the hub editor's default grid: see The hub editor surface). A new
  mission (the mission tool) =
  the fresh-mission template. New Campaign = campaign.txt + ONE
  default hub placed at `0 0` as the start hub (a campaign needs a
  start hub; no zero-start fresh state).
- **Pan**: the existing right-drag threshold gesture (the camera-pan
  seam input_gestures already arbitrates for the editor viewport) -
  right-drag pans, a sub-threshold release stays a clean right-click
  (delete). No new gesture machinery.
- **Auto-spread with authored directions**: unauthored EDGES (missions
  from the same start hub) spread
  evenly among THEMSELVES over the full circle; authored ones sit
  where placed. No gap bookkeeping.
- **Validation**: a Validate button (next to Save) runs the
  graph-integrity checks over the AUTHORED GRAPH in memory
  (checkCampaignGraph parameterized over a graph view instead of
  file reads - pure, no IO): unset/unresolvable start hub, dangling
  destinations, exits naming missing missions, unreachable hubs, the
  orphan findings above. Findings render through the standard warning
  surface.

### The hub editor surface (settled requirements)

The slice-4 drill-in (entered from the hub inspector's Open Hub Editor
button; returns via the world-map button). Mirrors the LEVEL editor as
closely as the content allows - same shell (tool palette bottom,
inspector left, metadata right), same grid machinery (the extracted
planners + selection algebra over the level-shaped hub grid;
`Selectable`'s hub arms: tile, decoration placement, NPC placement,
exit placement, player start).

- **The grid**: one tile grid per hub (no level tabs). A new hub's
  default grid is a SINGLE tile with the player spawn ('!') - the
  spawn keeps its mission-editor semantics (singleton, movable,
  never deletable). Placements are layout character codes (the
  shipped hub uses digits for exits, letters for decorations) - the
  level writer's per-tool-code machinery, unchanged.
- **Tools** (the active-tool model):
  - select: click-select + marquee + move-drag over the grid, the
    mission editor's selection algebra.
  - tile: paint/erase floor tiles.
  - an NPCs group - two FIXED tools (gear_upgrader, dream_guide;
    sprites derive from the type - nothing to author).
  - a Missions group - ONE TOOL PER OUTGOING MISSION (the missions
    whose start is this hub - membership is live from the campaign
    graph and changes when starts are re-wired on the map, the one
    live coupling between the two surfaces).
  - a Decorations group exactly like the mission editor's (palette +
    pickers, incl. hub-bundled custom art - the
    `custom/campaigns/<c>/hubs/<hub>/` stem rule).
- **Exit markers**: placing a mission's tool puts/moves THAT mission's
  marker (one marker per mission); right-click removes the marker but
  NOT the mission from the graph (it becomes unstartable - a
  validation finding). Exits are CLICK-activated in play (no pathing
  in hubs), so markers carry no reachability constraint.
- **The decoration palette is CAMPAIGN-SHARED**: dedup across all hub
  files on open, flatten back inline on save - the
  levels-share-the-mission-palette analogy. One decoration vocabulary
  across a campaign's hubs; fewer definitions to re-author.
- **The inspector**: default view EMPTY (no player.txt for hubs); NPC
  placements EMPTY for now (semantics arrive with NPC interaction);
  an exit marker shows a READ-ONLY summary (mission name, destination
  hub name, dangling marker when no destination) - all editing stays
  on the campaign map (name, re-attach, direction each have exactly
  one editing site).
- **The metadata sidebar**: hub name field + all three gradients
  ported from the level metadata (color_wheel_index + enemy/player
  overrides; hub.txt v5). The enemy gradient is unused at runtime in
  hubs (no enemies) - ported anyway for symmetry; revisit if it never
  earns its place.
- **NPC placement is free**: any number of each type, anywhere
  on-grid (NPC tiles aren't walkable - the blocking rule);
  restrictions, if any, arrive with NPC interaction semantics.
- **Save granularity per screen** (ctrl+S saves what the screen
  edits):
  - the campaign map saves the FULL campaign (campaign.txt + all hubs
    + missions - the reconciliation save, the ONLY save that deletes
    files; resolves every in-editor handle to a minted uuid through
    the session memo, missions first then hubs then campaign.txt).
  - the hub editor saves THIS HUB's hub.txt only. Exit entries whose
    mission or destination hub is still UNSAVED are skipped + warned
    (their uuid does not exist yet - nothing to reference); they stay
    in the editor graph and land at the next full save. A partial
    save never deletes anything.
  - the mission editor in campaign context saves the mission (its
    files in the campaign's `missions/`).
- **Exiting back to the campaign map NEVER autosaves** (settled):
  navigation is side-effect-free - the surfaces share one in-memory
  session (nothing is lost on return), crash recovery is the
  crash-dump session bundle, and quit-without-save matches the
  mission editor's explicit-save posture. Autosave-on-return would
  mint uuids on navigation clicks and spray the
  skip-unsaved-references warnings mid-workflow. If forgetting-to-
  save becomes a real pain, the answer is a dirty indicator (an
  unsaved-dot on the world-map button / top bar), never a write on
  navigation.
- **Hub-content validation findings** (folding into the campaign
  Validate button): an outgoing mission with no marker placed
  (unstartable); overlapping placements (two markers / NPCs /
  decoration footprints on one tile); placements off-grid.

### Known limitations

- Undiscovered hubs are DIMMED, not hidden - the full geography is visible
  on first view. Revisit for fog-of-war if the simple mirror spoils
  (TODO).
- Copy-at-pick imports FORK: a later edit to the original custom mission
  does not propagate into the campaign. Deliberate - the campaign dir is
  the source of truth; re-import is the refresh path.
- The one-edge rule FORBIDS shared missions (one mission enterable from
  two hubs). Deliberate - it keeps `start_hub` derivable and the graph
  honest; duplication or redesign is the author's answer.
- Dangling end hubs are tolerated (forward references), so a campaign can
  be SAVED in a state that does not fully resolve - the load-time graph
  integrity checks (slice 1: dangling destinations, exits naming missing
  missions, no placed start hub, unreachable hubs) + the eventual editor
  validation are the catch, not the save.
- Duplicate-uuid dirs resolve latest-mtime-wins + warning (see
  Uuid→dir resolution) - a deliberate tolerance of hand-edited installs,
  not a state the editor ever creates.

## Clones (clone system)

A **clone** is a per-mission record saved to `PlayerData.clones` on mission
completion. It captures how efficiently the run converted pickups into
materials: `materials_collected` (the summed salvage value of every item the
PLAYER picked up during the mission - counted at pickup time, regardless of
whether the item was later salvaged, equipped, or kept) over `turns_to_complete`
(`Mission.turns_spent`). Future completions of ANY mission **harvest** from all
saved clones, paying out `rate * turns_spent` per material where
`rate = clone.materials_collected / clone.turns_to_complete` (integer division).
So a clone is a permanent, compounding material factory keyed by mission.

- **Keying.** Clones are keyed by `mission_uuid` (see Custom Missions & Online
  Services → Content identity) - NOT by mission name (names can be duplicated
  across custom missions or renamed). `Clone.mission_uuid` is the identity;
  `Clone.name` is a denormalized display label carried for a future clones-list
  UI that renders without re-reading mission files. Consequence: `clones` IS
  the completed-missions record - the presence of a clone with a mission's
  uuid means the mission was completed (the world map / campaign view read
  completion state from it; no side channel, no per-campaign scoping needed
  - the uuids are random v4 ids, globally unique by construction).

- **Pickup accumulator.** `pickup_items` adds `computeSalvageValue(item,` 
  `salvage_definitions)` to `Mission.converted_materials_collected` for each item
  the player (entity_index 0) actually places into inventory. Leftovers that
  don't fit stay on the ground and don't count. Non-player pickups don't
  accumulate. The salvage value is measured at pickup, independent of what the
  player later does with the item - keeping it still counts toward the clone's
  rate (the rate is "how efficiently did this run convert pickups into
  materials," not "how much did the player salvage"). The actual
  `salvage_item` event still adds materials to `player_data.materials`
  separately (unchanged).

- **Completion flow** (in `end_level`'s last-level `.default` branch, after
  the completion sound, before the trailing `end_mission` push):
  1. Read `mission.{uuid, name, turns_spent, converted_materials_collected}`.
  2. Find an existing clone by uuid. Compare TURNS: a strictly faster run
     (`turns_spent < old.turns_to_complete`) is the new personal best -
     the same rule as the validation replay's overwrite guard
     (`validation_replay.replayOverwriteDecision`): strictly faster wins,
     ties and slower runs keep the old clone. Materials do not factor
     into the decision (they still set the new clone's harvest rate -
     that model is unchanged).
  3. Gate the whole block on `turns_spent > 0` (div-by-zero guard for dev
     skip-through via `player_skip_level`).
  4. **Harvest** (`harvest_clones` SuperEvent): sum over ALL existing clones,
     per material `rate * turns_spent`, add to `player_data.materials`. The
     just-completed mission's new/updated clone does NOT contribute to THIS
     run's harvest (it pays out on future completions) - harvest runs before
     `save_clone_info` (LIFO).
  5. **Auto-save clone** (`save_clone_info` SuperEvent): if no existing clone
     OR strictly faster, replace/append. Otherwise set
     `MissionCompleteInfo.overwrite_offered = true` and DON'T auto-save - the
     overlay offers a manual "Overwrite Clone" button (`player_overwrite_clone`
     PlayerInputEvent → pushes `save_clone_info` from the `MissionCompleteInfo`
     snapshot, since the `Mission` is gone in the hub).
  6. `MissionCompleteInfo` carries `{uuid, name, path, turns_spent,
     converted_materials, overwrite_offered}` so the hub-side overlay + the
     manual-overwrite orchestrator can reconstruct `save_clone_info` from the
     timeline info alone - the `Mission` is gone by the time the overlay
     renders in the hub.

- **LIFO push order.** The trailing push block (shared across all level-exit
  continuations) builds the exit-event array as `[write_save, save_clone_info?,
  harvest_clones?, build_data_from_player]` so execution order is
  `build_data_from_player -> harvest_clones -> save_clone_info -> write_save`,
  then `end_mission` (pushed earlier in the `.default` branch) runs last.
  Harvest reads the OLD clones (before save_clone_info replaces/append);
  write_save persists the post-harvest, post-clone-save PlayerData. The
  harvest/save events are only pushed on `.default` last-level completion
  (not restart/exit/abandon).

- **Replay safety.** `save_clone_info` + `harvest_clones` are SuperEvents
  (machinery, handler-pushed), never whitelisted in `isPlayerAction` (a replay
  log can't seed them at an idle point). They're pure state transforms
  (`PlayerData` mutation) reproduced on replay - no side-effect gating needed
  (no file writes / sound / anim at the handler site; the `write_save` that
  persists the result is separately gated `!replaying`).

- **Integer division rounding.** Payout is `(materials_collected * turns_spent)
  / turns_to_complete` per material, with the MULTIPLY before the divide and
  a u64 intermediate. This matters when a clone's per-turn rate is
  fractional (materials < turns_to_complete): dividing first truncates the
  rate to 0 and pays out nothing, which is how the real Beginnings clone
  (11 wood / 49 turns) harvested 0. Multiplying first pays the cross-product
  before one truncating divide, so the loss is `< 1 per material per
  harvest` (the fractional remainder) instead of possibly 100%. All gameplay
  logic stays integer (AGENTS → Code Style); no fixed-point state needed.
- **Saturation.** Material wallet ADDS clamp at u32 max, never wrap
  (silent wraparound would destroy wealth) - see Post-game Rewards &
  Cosmetics → Overflow guard.

## Gear Upgrading (the upgrade economy + hub vendor panel)

Gear upgrading is the player's POWER progression: materials earned through
the clone economy are spent at a hub vendor NPC to raise the stats of
equipped or carried gear. Found loot provides variety and materials, not
power; authored boss gear provides the big jumps; an on-pace player who
completes the campaign ends it exactly fully maxed with empty wallets.
Implementation is deferred (TODO → Gear Upgrading) - this section is the
settled design. All prices are tuning starting points; the anchors and
audit identities at the end are the invariants.

### The income model (extracted from the clone design)

Two measured constants describe the economy, and only their product is
used:

- **N = 0.6** materials per turn per wallet (material type) - the measured
  clone/pickup rate, assumed uniform across the five wallets (a smoothing
  assumption; measured flows are lopsided per mission - Beginnings is
  wood-only).
- **T = 45** - average mission turns.
- **R = N·T = 27** - materials per wallet per mission of progression.
  The current mission's own pickups flow at the same rate as the clones
  (the clone rate IS the pickup rate; kept gear and learned tomes are
  one-time differences that amortize to nothing), so direct income and
  harvest merge into the one constant:

```
I(m) = R·m                paycheck per wallet after completing mission m
W(m) = R·m(m+1)/2         cumulative wealth per wallet
```

Anchor values: **W(3) = 162** (the b-line), **W(66) = 59,697** (campaign
completion), plateau paycheck **I(66) = 1,782** per replayed mission. All
design math is real; prices are integers derived from it (rounding rule
below).

**The enemy drop stream is inside R, not beside it.** Dead non-player
entities drop their equipped gear, inventory contents, and a skill tome
per equipped utility skill (the uniform death rule); salvage value counts
at pickup, so all of it is part of the measured rate. Consequences:

- R is a MEASURED aggregate - enemy gear richness and utility-skill
  density are content dials that move it. The sparse-enemy-gear rule for
  official missions (most enemies have unpopulated slots) is balance +
  inventory management + **R stability**. Re-measure when that content
  changes.
- The pickup accumulator only counts items that fit; overflow stays on
  the ground and silently depresses the measured rate - absorbed into
  the measurement, but a content lever to know about.
- Knowledge's real sources are amulets/staves/idols plus enemy utility
  tomes - the uniform-0.6 knowledge assumption is softened by the tome
  stream but stays content-dependent (spell upgrades are the de-facto
  premium; the α table leans the same way).

### The anchors

- **T(3) = 75% tier** - a b-lining player (3 missions completed before
  the arm's boss; no central starter mission) holds gear at 75% of every
  stat's max, rounding down: weapons/spell 7 of 10, health 7, defense /
  damage / pickup 3 of 5, speed 1 of 2. Bosses are tuned to this tier
  ("challenging but possible from a new game").
- **T(66) = 100%** - the main campaign is 66 missions; the on-path player
  (every mission, every boss, spends everything) completes it exactly
  fully maxed with empty wallets. Skipped bosses and optional missions
  are slack in both directions.
- Between the anchors the tier frontier climbs linearly (below); drops
  make it a staircase (jumps at bosses).

### The cost ladder (the mid-game segment)

Every price is a pure function of (stat, current value) plus config -
static, deterministic, replay-trivial. The ladder is anchored at the
standard starting stats, so the first point above starter gear costs
~one early paycheck:

```
cost(stat, v → v+1) = α_stat · K · R · (1 + (v − s_stat) · d_stat)   [parts]
```

- **s_stat** - the standard starting value per stat (weapons/spell 3,
  health 1, minors/speed 0), DERIVED from `data/new_player.txt` at load -
  no hand-maintained constant.
- **K** - the number of materials in the item kind's salvage split
  (weapons use their weapon-type salvage definition). The cost splits
  across those materials in the salvage ratio - upgrading a sword is
  metal-heavy, a staff knowledge+wood, boots cloth+leather - mirroring
  what salvaging that item yields. Integer rounding: floor each
  material, distribute the remainder by largest fraction (deterministic).
- **d_stat** - missions of progression between points: 1 for 10-max
  stats, 2 for 5-max stats.
- **α_stat** - the wallet-binding solve at the b-line anchor: demand
  from starter gear to the 75% tier (all equipped items) is distributed
  so every wallet drains to exactly zero at the tier. The ranking is
  forced by the wallet mix (four armor pieces draw cloth+leather vs two
  weapons on wood+metal vs one amulet on knowledge, against uniform
  income) and independently reads as design intent - survivability is a
  cheap drip, weapon points are weighty, spell points are premium.
  Per-stat α is the wallet-mix balancer.

| stat group | α | first purchase | tier-completing purchase |
|---|---|---|---|
| armor (health/defense/damage/pickup) | 0.054 | health 1→2 ≈ 3 parts | health 6→7 ≈ 17 parts |
| weapon_damage | 0.30 | 3→4 ≈ 16 parts (sword ≈ 4 wood + 12 metal) | 6→7 ≈ 65 parts (≈ 16 wood + 49 metal) |
| spell_damage | 0.60 | 3→4 ≈ 16 knowledge | 6→7 ≈ 65 knowledge |

- **Ladders are keyed by stat, shared across item kinds** - health_bonus
  prices identically on coat/gloves/pants/boots; weapon_damage prices
  identically across weapon types (only the split varies). A stat the
  kind doesn't carry never appears; skill tomes carry none and are
  excluded from the panel by construction.
- **Speed is the deliberate outlier**: 0→1 costs ~3 parts (trivial);
  1→2 is a TAIL purchase (below) - the single biggest purchase in the
  game, and never on dropped boots in the official campaign (custom
  missions are unrestricted; `itemStatMax` still bounds them).

### The tail + tier frontier (75% → 100%)

The frontier T(m) climbs linearly from 75% at m=3 to 100% at m=66: a
10-stat's value-8 rungs land around m ≈ 16, value-9 around m ≈ 41,
value-10 at m = 66. Each rung's price is its wallets' share of the
WEALTH GAP between frontier crossings - and because W is quadratic, the
escalation is automatic: the gaps are ≈ 3.5k (m 3→16), ≈ 19.6k (16→41),
≈ 36.5k (41→66) parts per wallet, so late rungs cost thousands of parts
each (multiple plateau paychecks) while mid rungs cost tens. "Stats
closer to max cost significantly more" falls out of the income curve,
not a ratio knob.

The tail's exact integer prices depend on the boss drop table (drops
pre-pay tail rungs - see below), so they are GENERATED, not hand-set: a
design-time script (the sound_report.sh pattern) regenerates the tail
price table from the model constants + the drop schedule whenever
either changes. The mid-ladder derives at load from config constants;
the doc ships the solve machinery + the audit identities.

### Drops: found gear is pre-bought rungs

The model tracks stat points, never items: prices are keyed by current
value, so a found item has simply skipped the rungs below its value and
prices identically from wherever it sits. The anchors pin TOTAL gear
power - starter + drops + purchases - however the points got there.

- **Regular drops are variety + materials, not power.** Enemy gear drops
  with low/flat rolls; the invested-item-stays-ahead rule makes spending
  rational (no hoarding pathology: an invested item is never strictly
  superseded by an uninvested drop).
- **Boss drops are authored gear, not a mechanic.** The uniform death
  rule already drops whatever the boss carries - the "cool 9-damage
  weapon" is high-stat equipment authored on the boss entity. 9-of-10
  deliberately leaves the final rung purchasable. Twelve bosses vs seven
  gear slots: spread drops across slots and weapon types (content rule);
  redundant drops salvage - negligible money (salvage values are flat per
  item type against a 59k/wallet economy). Boss gear pre-pays the
  expensive tail rungs: richer drops trade directly against grind.
- **Player-knowledge texture**: once players learn bosses drop
  high-value gear, deferring tail purchases on a covered slot is the
  smart play - economy skill, a feature.
- **L(3) = 0** - the b-liner has beaten no bosses when they arrive at
  the first one; the 75% anchor is unaffected by drops.

### The surface: vendor NPC + two-column panel (wiring deferred)

- Each hub has an upgrade-vendor NPC - the first real consumer of the
  `interact_with_npc` handler (currently a `{}` stub; the hub click site
  is marked in handleIdleInput). The hub format gains a way to mark an
  NPC as the vendor (exact authoring shape decided at implementation).
- The panel is a middle panel, two columns: an ITEM LIST of all
  upgradeable items (equipped or in inventory - every item with a
  nonempty `itemStatSet`; skill tomes excluded by construction), and the
  UPGRADE VIEW for the selected item - per stat: current value / max,
  cost in materials, an upgrade button (disabled when unaffordable,
  "MAX" when maxed).
- Panel open/close lands on the TARGET convention of the panel-toggle
  unification (TODO → Tech Debt): a GameState event on the undo
  timeline. Item selection within the panel is pure UiState (the
  inventory-slot-selection pattern).
- **Events** follow the equip/salvage shape: a `player_upgrade_item`
  PlayerInputEvent orchestrator (item reference - gear slot or inventory
  index - plus ItemStatField) whitelisted in `isPlayerAction`, with a
  `validatePlayerAction` arm over a bool legality helper (item exists,
  stat applicable, not maxed, materials sufficient - computed from the
  same derived price table); the machinery `upgrade_item` PlayerEvent
  mutates PlayerData and re-syncs the equipped entity's gear stats (the
  entity↔PlayerData sync machinery). Pure state transform + queued sound
  gated `!replaying`; no turn cost (hub activity); commits clamp to
  `itemStatMax` (the existing single source of balance bounds).

### Audit identities (the tuning tools)

- **Wallet-binding at m=3**: cumulative demand from starter gear to the
  75% tier drains all five wallets to zero simultaneously (the α solve).
- **End-state identity**: starter + 12 boss drops + purchases = the 100%
  tier at m=66, purchased demand ≈ W(66) − drop-covered rung shares.
- The full-loadout demand curve is diffable against W(m) at every m -
  starvation/swimming is visible before content is authored.

### Post-game

The post-completion material sink is designed - see Post-game Rewards &
Cosmetics. The compositional fact stands: the campaign ends
wallets-empty, so the post-game economy starts fresh.

## Post-game Rewards & Cosmetics (decoration base-builder + weapon skins)

The post-completion material sink. LOW PRIORITY - the official campaign
comes first (TODO notes the same); this section is the settled design so
the economy work above stays coherent with it. The income it absorbs
scales indefinitely: dreams run the official mission lifecycle (DESIGN
→ Custom Missions & Online Services → Dreams), so custom missions clone
and harvest exactly like official ones - **every mission ever completed
adds ~R = 27 materials per wallet to every future mission's paycheck,
permanently** (a portfolio of K missions pays 27·K per wallet per
replayed mission). The sink's job is to give that scaling a destination.

### Overflow guard (saturating material adds)

Materials are u32 per wallet. Every add clamps: the wallet
sites (clone harvest, salvage, the pickup accumulator) all go through
`Materials.add` (`+|` per material), the harvest payout itself
accumulates in u64 and clamps at u32 max per material, and the salvage
share math (unbounded `parts` config) runs its intermediates in u64
(the result is bounded by the item's total value by construction).
Honest-play numbers put overflow far out of reach
(~17,800 distinct missions completed, or ~2.4 million replays of the
official portfolio, to hit u32 max cumulatively), but custom content has
no bound on clone count or pickup density, so a crafted "farm" mission
is the real worst case (~10×, still thousands of completions). The
failure mode is silent wraparound destroying wealth, so the rule:
**material adds saturate** - the clamp lives in `Materials.add`
itself (`+|` per material), so every wallet-add site (the clone
harvest, salvage, and the pickup accumulator) clamps at u32 max rather
than wraps. The shop ladder's top tier (below) doubles as
the drain valve toward that ceiling. Save size is a non-issue
(~100-200 bytes per clone).

### Hub decoration customization (central hub only)

- **Scope**: the central hub only - one persistent home-base surface;
  every other hub stays authored. One save surface, one hub's fixtures
  for the placement rules.
- **Persistence**: a placement list on PlayerData - {decoration type
  id, tile position, color index} - applied as an overlay when the
  central hub builds. The hub definition itself stays embedded and
  untouched; replay-safe because it rides PlayerData exactly like
  gear.
- **Placement machinery reuses the editor's decoration tooling**:
  footprint overlap + occupant-conflict checks (never cover mission
  exits, NPC tiles, or the player start), the decoration registry
  (data/decorations.txt) as the catalog, per-bbox-tile split rendering,
  cursor footprint previews. A hub build mode is the editor's decoration
  planner consumed by a hub screen, minus the editor chrome.
- **Ownership is buy-once-place-freely**: purchasing a decoration type
  is a permanent unlock; place/move/remove freely from the owned set.
  No refunds to design - placement is free, purchase is the cost.
- **Build-mode entry is UNDECIDED** (TODO) - how placement mode is
  reached (an NPC flow, a button, a shop segue). The dreamguide is its
  own separate NPC in every hub either way (DESIGN → Browser).

### Weapon skins (weapons only, for now)

- **Registry per weapon type** - alternate sprite ids for the
  player-team rendering path (`weaponSprite` in view.zig is the single
  insertion point); the `enemy_` path is unchanged; off-hand mirroring
  comes free (`flip_horizontal` on the resolved sprite). Other gear
  slots don't render as sprites today, so "skins" means weapon skins
  until that changes.
- **Selection is per weapon TYPE, not per item**: PlayerData carries
  the unlocked set + a selected skin per type. Stable across the
  equip/drop/salvage flow, tiny, replay-safe (cosmetic - rendering
  only).
- **One unlock mechanism, both sources**: picking up an item flagged
  with a skin id grants that skin permanently. Official content: boss
  weapons carry unique skins (the 9-damage flex drop is power AND
  bling). Custom missions: authors flag their own drops the same way.
- **Custom missions ship skin art from the first version**: the skin's
  PNG lives in its source mission's directory under the existing
  namespaced id (`custom/<mission-dir>/<stem>`) - resolvable from the
  persistent missions/ dir at any time, not just while that mission
  plays. Fallback rule: a skin whose art cannot be resolved (source
  mission deleted) renders the type's DEFAULT sprite and the picker
  greys it out - no magenta swords for a deleted cosmetic (the
  missing-art convention applies to shipped content, not to
  player-optional cosmetics).
- Skins are cosmetic: no balance bounds involved; custom art follows
  the existing custom-sprite rules (dims resolution, no gameplay
  effect).

### Pricing: a static tier ladder (the "keeps up" design)

Postgame income is a function of each player's own content
consumption, so wealth scales differ by orders of magnitude across
players - and the ladder absorbs that structurally, WITHOUT the dynamic
pricing rejected for upgrades (it would punish grinders and read as
the game cheating):

- **A deep catalog with tiers ~×10 apart**, spanning ~6 orders of
  magnitude: ~100-1,000-part decorations (mid-campaign cozy tier),
  ~10k-100k (early postgame), ~1M, ~10M-100M, and a top flex tier in
  the hundreds of millions / low billions - deliberately near the
  wallet ceiling, so the deepest grinders drain toward safe territory.
- **Evergreen catalog growth**: new decoration + skin sets ship with
  game updates, priced at the then-current meta scale - the catalog
  keeps up with the ecosystem by growing with it.
- **Self-gating, no completion flag**: the shops exist anytime; prices
  gate. A new player seeing the ladder understands instantly what
  endgame wealth is for.

## Architecture

- Elm-like: main (init), update (state transform), view (render)
- Event stack (LIFO) on GameState, processed one at a time. When empty, waits for player input
- **Events are generic state-mutation verbs, not skills.** Each event mutates
  one dimension of entity/level state (health: `attack`/`heal`; momentum:
  `change_momentum`; cooldowns: `change_cooldown`; position: `move_entity`/
  `swap_positions`/`knockback`/`retreat`; status: `stun`/`create_effect`/
  `end_effect`; world: `aggro_check`/`pickup_around`/`death`) - a basis set
  over the mutable fields. A skill is a recipe: its `useSkill` computes and
  emits a sequence of these generic events. All skill-specific cleverness
  (conditionals, multipliers, radius loops) lives in `useSkill`, never in a new
  event. Only add a new event when a skill must mutate a state dimension no
  existing event covers; prefer composing existing primitives. Reactive
  mechanics (e.g. Reflect) belong in the effect system, not as skill events.
  **Reflect does not intercept collision damage - deliberate counterplay.**
  The `attack` handler routes damage through the defender's damage
  interceptors (the transform stage); the `collision` handler deliberately
  skips that fold. Knockback into an obstacle is the intended way to deal
  damage through a Reflect shield, so the skill/effect descriptions say
  "incoming ATTACK damage". Any future interceptor inherits the same
  attack-only scope.
  **Damage apply is split from hit resolution (the `damage` event).**
  `attack` and `collision` are RESOLUTION stages (aggro activation, their
  own effect callbacks, the intercept fold - attack only - + defense) that
  hand the resolved post-defense amount to one shared `damage` apply arm:
  health, mission stats, hit flash, damage number, the damage callbacks,
  death push, lifesteal. Two reasons: the apply pipeline existed as two
  near-identical blocks in the attack/collision arms (composition removes
  the seam - the primitive-composition rule below), and the event boundary
  puts a place for pacing between a hit's resolution and its damage landing
  - an intra-hit `effect_step_wait_milliseconds` wait is pushed at both
  push sites (sound stays in sync with its source event; a
  presentation-layer stagger was rejected for exactly that reason). The
  impact sound (`SoundId.damage`) is queued by the apply arm, so sound +
  flash + number land together. Combat-log tier `.none` - the
  attack/collision entries already represent the hit (revisit when the
  detailed-log UI lands).
  **Skill pacing (the generic rule - ACCELERATING waits).** Every skill
  that pushes more than one event gets a pacing wait between each
  consecutive pair - interleaved MECHANICALLY by `helpers.ownedEvents` (the
  one constructor every recipe's list goes through), in natural execution
  order before the LIFO reversal. Skills never insert waits themselves;
  pacing derives from the list length, so a new multi-event skill is paced
  for free and forgetting one is structurally impossible. Lists of 0/1
  events pass through unchanged.
  The wait is `accelerating_wait` - an EMPTY-payload `wait` variant whose
  duration is COMPUTED at pop time: `effect_step_wait_milliseconds` (125ms)
  decayed by 3/4 per prior gap in the chain (integer math, floored at 1ms -
  125, 93, 69, 51, 38, 28, 21, 15, 11, 8, 6, 4, 3, 2, 1 - a long chain winds up
  instead of
  dragging). ONE shared sequence per skill use: the attack/collision arms
  push the SAME variant for their hit-resolution → damage-landing gap, so
  a multi-hit skill's rhythm accelerates across its whole chain (spinblade
  ×3: attack → 125 → damage → 93 → attack → 69 → damage → 51 → attack →
  38 → damage). The counter is `GameState.wait_acceleration`, reset by the
  ONE chain start - `use_skill` (every attack is skill-mediated: the
  player's attack step IS a weapon-skill use, enemies cast through
  bestCasts, and adrenaline_surge's handler-pushed attacks ride the
  use_skill reset). Replay-safety: the counter is event-driven GameState
  (reset + increments are handler transforms), carried in snapshots and
  recomputed identically on replay/undo - the derived durations stay
  deterministic WITHOUT carrying them in the payload (which is why the
  counter must NOT live on SessionState - unreplayed state would diverge
  on undo). The plain `wait` event (500ms turn flow) is untouched.
  Scope: a skill's OWN authored list plus the hit-landing gaps -
  effect-triggered lists (Reflect's counter-hit, That-Which-Explodes' AoE)
  and handler-composed follow-ups (death, the lifesteal heal) resolve
  immediately; those are causal consequences of one event, not an authored
  sequence. Accepted costs: recorded-log growth (+1 wait per gap) and the
  drain latency on large AoEs - mitigated by the decay (a packed meteor
  converges toward simultaneity).
  **Aggro + level-end are decoupled.** `aggro_check` (no payload) scans every
  inactive entity and activates it if it sees an opposing entity within ITS
  OWN `aggro_range` - self-centric, one event covers the whole level. Pushed
  at level start (single event, not per-entity) and after every `move_entity`.
  **Hostile-effect activation:** being the DEFENDER of a hostile effect
  activates an inactive entity regardless of range - an `attack`, `stun`,
  `knockback`, or `collision` landing on it, or being the `swap_positions`
  target (entity_b). Targeting counts even when the effect is fully
  mitigated (Reflect zeroing the damage, future invulnerability) - the
  entity was targeted. Implemented as a one-line `activateEntity` call at
  the top of those handler arms (no new event, no log/replay schema change
  - the `is_active` flip is a pure state transform; the anim side effect is
  already replay-gated inside the helper). Skills can therefore never snipe
  an inactive enemy from beyond its `aggro_range` for free: damage or
  targeting aggros it. `adrenaline_surge`'s strikes are emitted `attack`
  events, so it's covered transitively. NOT covered: same-team/self buffs
  (`heal`, `change_momentum`, `change_cooldown`) - hostile momentum
  transforms (Tier B) extend the rule when they land. The player (entity 0)
  may be "activated" by enemy attacks - harmless by convention (loops skip
  entity 0).
  `check_level_end` (no payload) is the win condition: if the player is on
  `level_end` and no active enemies remain → push `end_level` (the shared
  predicate `Level.hasActiveEnemies` - the same one the attack-step
  auto-skip and the flag banner gate on; see Animation). Pushed after
  `aggro_check` (LIFO → runs after, so newly-aggroed enemies are counted)
  and after `death` (killing the last enemy while standing on the exit ends
  the level without an extra move). Not pushed at level start (player spawn
  and level end are always different tiles).
  **Prefer composing an existing primitive over re-implementing it.** When a
  second event/skill does semantically what an existing one does, reuse the
  primitive (push the existing event) instead of re-implementing the
  behavior - this keeps all post-effects in one place. `swap_positions`
  pushes two `move_entity` events (so sound, momentum, pickup, aggro,
  level-end all fire uniformly); `aggro_in_radius`, `aggro_check`, and the
  hostile-effect activation sites share an `activateEntity` helper so the
  aggro-indicator anim can't drift between
  them. Where you can't compose (different range source or team filter),
  extract the shared core into a helper and leave a comment naming the ONE
  intended difference. The seam between sibling implementations is where
  silent drift bugs live; composition removes the seam.
  Scalar-field primitives clamp (heal to max_health; momentum/cooldown at 0 via
  functions.applySignedDelta). Stun is the one scalar shaped by counterplay
  rather than clamping: a new stun takes the MAX of current vs incoming
  duration, never the sum - multiple stunning enemies cannot mega-stunlock
  the player (a shorter stun on an already-stunned target changes nothing;
  a longer one replaces it). Stun skills' AI mirrors this: they rate up only
  when an unstunned target is in reach and select unstunned targets first
  (`skill_helpers.zig` `stunTarget`).
- **AI options (the unified enemy decision surface).** A skill's
  `ai_options_fn` enumerates its meaningful casts as (target, rating)
  pairs, best-first - ONE decision instead of the old priority /
  selectTarget pair, whose summary-vs-argmax split produced documented
  seams (bash rated "any colliding target" while selection attacked
  another; flash strike rated one landing tile and landed on another;
  stab rated off a healthy target it then didn't attack). The handler
  (`enemy_turn_attack`) collects options across equipped off-cooldown
  skills, keeps the turn-ending / non-ending pools (by skill_type), and
  picks `(priority desc, option order, slot order)` - options arrive
  best-first so the ordering conventions (focus-fire tail, collide /
  unstunned preference keys, the AoE bump) live in the emission order.
  Only the enemy AI consumes this - the player path
  (getValidTargets/player_prepare_skill/use_skill + legality validation)
  is untouched. `target` is exactly what gets passed to useSkill (null =
  self-cast / self-centered; flash strike's target is its landing tile).
- **AI threat model (defensive-skill evaluation).** `Skill.deals_damage`
  (a required field on every skill definition) marks whether useSkill hurts
  anything. `ai_threat.zig` turns that into reach math:
  `computeMaxDamageRange` = max effective (range ?? radius) over an entity's
  equipped, off-cooldown, DAMAGING skills; `hostileCanAttackNextTurn` = any
  hostile that is alive, active, unstunned, and within
  `effective speed + max damage reach` (Chebyshev - obstacle-blind, the
  overestimate being the safe direction for a defensive cooldown; a
  pathfinding refinement is a later polish pass). Defensive skills (Absorb,
  Reflect) rate on it: 0 unthreatened, 2 threatened, 4 threatened + below
  half health (the 4 must outrank Heal's 3 on the idol bar - prevention +
  conversion beats a flat 20% when the hit is coming). `computeMinRange`
  (moved to ai_threat.zig from the level handler) deliberately still counts
  every usable skill - min answers "when can I act", max answers "how far
  can I hurt"; a control-only enemy (e.g. Daze) should stop and cast from
  its range, not walk adjacent first. To reach this math from a skill
  priority fn, `priority_fn` receives the session's
  `weapon_type_definitions` (slot resolution needs the mapping - the same
  constraint that made Focus an orchestrator; most skills ignore the param).
- **AI movement modes (`ai_movement.zig`).** `enemy_turn_move` picks
  ONE mode per entity per turn (`selectMovementMode`), off the CURRENT
  cooldown state - a point-blank skill on cooldown does not shape that
  turn's movement:
  - `Skill.point_blank_area_of_effect` (defaults false - a forgotten flag
    only makes the AI dumber, not wrong) marks skills whose AoE is centered
    on the caster (spinblade, slam, blitz, howl, worldfire, burst, drain,
    shockwave). An OFF-COOLDOWN offensive (deals_damage) point-blank skill on
    the exposed combat bar (collectSkillSlots - the same pool
    enemy_turn_attack casts from) selects `.point_blank_cluster`: the
    entity moves to the reachable tile (current tile included) with the
    most hostiles inside one of those skills' effective radius, preferring
    the current tile on ties (no shuffling). Null when no candidate has
    any hostile in radius → approach (nothing to cluster around).
  - Otherwise, when the kit's off-cooldown `computeMinRange` exceeds melee
    (> 1), `.keep_range`: among reachable tiles from which the entity can
    still act (some hostile within min range), pick the one FARTHEST from
    its nearest hostile - approach converges on min range from outside,
    kiting opens to it from inside; both modes meet at the same distance.
    Cornered → the current tile stands. Null when nothing is act-capable →
    approach (close the gap first).
  - `.approach` (the historical behavior): converge on the nearest hostile
    up to min range, pathfinding with a reachable-tile fallback - kept in
    the handler (level.zig `enemyApproachTurn`); the fallback's distance
    ties break by the same straightness rule.
  Destination ties: an equal-value candidate NEVER displaces the current
  tile - stay put unless a strictly better tile exists (shuffling between
  equal options reads as noise to the player); ties between reachable
  tiles break by the straighter line to the caster's nearest hostile
  (`functions.straighterTileBefore` - Determinism & Tiebreaking), then
  the (x, y) tile convention.
  The modes are MOVEMENT only - the attack phase's
  ai_options evaluation is untouched; a cluster-seeker that moved in but
  has its skill stolen by slot order still attacks from the cluster tile.
  Known limitation: keep_range maximizes distance to the NEAREST single
  hostile - retreating toward a second enemy is possible; multi-hostile
  avoidance is a future mode.
- **AI rating scale (value units).** A cast's priority ≈ its value in
  units of a plain 1x hit: 0 = don't cast, 1 = a plain attack, +1 per
  significant bonus - a conditional damage multiplier, a stun landing on a
  non-stunned target, collision damage, a control effect worth ~a hit.
  Lifesteal counts only when the caster is below half health (sustainability
  is not tempo). Minor riders (±1 momentum, non-colliding knockback
  displacement) count 0. AoE ratings sum PER TARGET
  (`helpers.aoePriority(count, base)` = base + count − 1, base 1 for a
  plain per-target hit, 2 with a global rider worth a hit - Flash Strike's
  teleport; `helpers.aoeKnockbackPriority` adds +1 per target whose push
  would collide, counted via `helpers.collidingTargetCount` - per-
  colliding-target is honest for an AoE, the cast has no target choice).
  Counts come from `helpers.hostileCountWithinRadius` (allocation-free,
  center-parameterized so Flash Strike reuses it per candidate landing
  tile, taking the max); Howl counts inactive entities of any team
  (aggro_in_radius rallies same-team entities too). Ties mean equal value,
  and the handler's slot-order tiebreak then prefers the skill further
  left - which makes weapon skills win equal-value ties against utility
  spells (the cheaper slot, generally the shorter cooldown). This is what
  resolves "1-target Spinblade vs Charged Bolt": 1 < 2, the single-target
  skill wins.
- **Enhancement enchantments rate against their LIVE beneficiaries
  (+1 ordering rule).** An enchantment that enhances subsequent casts
  rates itself = (best live-beneficiary rating) + 1, so it always fires
  BEFORE the cast it enhances in the non-ending chain. A "live
  beneficiary" is a cast that will actually happen this turn: the PLANNED
  turn-ending cast (via `ai_select.bestCasts`'s `ending` field) if its
  Skill base values carry the enhanced field (stone form: `stun_duration`;
  lingers: durations; reaches: range/radius; rushes: a cooldown > 0
  (the −1 applies to each cast's newly-set cooldown); bull form:
  distance), plus
  any positive-rated NON-ending skill with the field (all positive
  cantrips/enchantments fire this turn - a future stun cantrip or stun
  enchantment slots in automatically). No live beneficiary → the
  enchantment's own fallback gate (stone form: the end-of-turn heal,
  rating 1 below full health; never cast early on a beneficiary that
  rates 0). The plan is re-derived after every cast in the re-evaluation
  loop, so an enchantment's rating self-corrects as the plan changes.
- **The virtual-effect sim differential (reaches, bull form).** When the enhanced field GATES whether casts are possible
  (range/radius gate target availability; distance gates collision
  ratings), the base-value rule isn't enough - the valuable case is the
  +1 FLIPPING an impossible cast into a possible one. The enhancer
  re-evaluates the whole bar with its own effect virtually applied
  (`helpers.bestCastsWithVirtualEffect`: shallow-clone the entities,
  append the effect to the cloned caster - the denormalized modifiers
  copied from the effect definition - run `bestCasts` against the
  simulated state) and compares plans (`ai_select.plansDiffer`: any
  difference - different skill, target, or rating, or a plan appearing -
  is the modifier's doing). A differing sim plan's rating counts as a
  live beneficiary, max'd with the base-value rule. The sim frame is
  FRESH (the pass frame's memos are for the real state - virtual-modifier
  results must never leak into the real plan) and INHERITS the caller's
  in-progress set plus the simulated skill - without the inheritance, two
  sim-based enhancers equipped together would alternate through each
  other's sims forever. Duration-type modifiers (lingers) do NOT use the
  sim: they modulate magnitude, almost never flipping a rating - the
  base-value rule carries them.
- **AI cast selection lives in ONE place (`src/ai_select.zig`) behind the
  pass-scoped `EvalFrame` (skill.zig).** `bestCasts` is the exact
  selection `enemy_turn_attack` applies (partition by skill_type,
  0-skip, strict-best with slot-order tiebreak). EVERY option evaluation
  goes through `ai_select.optionsFor(frame, skill_id, ...)` - never call
  a skill's aiOptions directly: within one re-evaluation pass the game
  state is frozen, so options memoize once per pass, and the in-progress
  guard cuts consultation cycles mechanically (a skill whose aiOptions is
  transitively being computed returns empty options - also the correct
  semantics: an enhancer scanning beneficiaries must not count itself).
  No structural restrictions (pool separation, beneficiary-type
  filters, one-way edge conventions) are needed - any skill may consult
  any set of skills through the frame; the handler opens each pass with
  a fresh frame (never on GameState, never serialized - replay-safe by
  construction).
- **Utility skills deal spell damage - always.** Any damage a utility
  skill (spell / cantrip / enchantment / curse) deals - directly or via
  its effect's reactive attacks (That Which Explodes) - uses
  `Entity.getEffectiveSpellDamage` (the amulet pipeline). Weapon skills
  use their hand's weapon damage; idol weapon skills are weapon skills,
  not utilities, and follow the weapon rule.
- **Cooldown-reset scopes differ by direction.** Adrenaline Surge (cast on
  an ENEMY) resets only the target's ON-BAR cooldowns
  (Entity.onBarSkillIds) - the bar scope keeps the swap-inheritance
  exploit out: a player rotating many skills stacks inherited cooldowns,
  and each would add an attack (reflectable by shield 3) - hidden and
  broken. Promise of Death (cast on SELF) does the FULL sweep, including
  off-bar preserved cooldowns - a self-buff has no count-driven damage to
  inflate, so there is nothing to exploit.
- **Skill design principles (speedrun-first, no built-in downsides).** The
  game's goal is speedrunning encounters, so a skill must never forcibly
  extend an encounter (stall mechanics that make the fight longer no
  matter what the player does) and must never take control away from the
  player for more than an instant. Related: NO built-in-downside skills
  (self-stun, self-damage as a cost) - a cost paid by degrading the
  player's own agency feels bad and is avoided at all costs; skills pay
  via cooldowns and momentum, never by locking the player out of their
  turn. Diamond Form (self-stun 5 + invulnerability + end-of-turn heal)
  is the removed precedent: implemented from the original Unity design
  doc, then deleted - its use forced any encounter to run ≥5 extra turns
  with zero player decisions. When porting the remaining Unity designs,
  screen them against these principles first.
- **Skill logic always reads EFFECTIVE values.** Any gameplay read of an
  authorable number goes through the `getEffective*` methods (range,
  radius, distance, damage pipelines, stun/skill durations, cooldown at
  the set site, max health). Raw field reads (`weapon.weapon_damage`,
  `skill.range.?`, ...) are legal ONLY as the base input handed to a
  `getEffective*` call, and only runtime counters (cooldown clocks,
  current stun duration, current health) are read raw directly. The
  That-Which-Explodes hardcoded radius was the one audit catch - effects
  read their host's effective values too.
- **Damage multiplier ordering (multipliers apply last).** When a skill
  scales its damage (Throw/Retreating Swipe/Impale's 1.5x, Skewer's 2x,
  Chop/Stab/Slice's conditional 1.5x), the multiplier applies to the
  FULLY-MODIFIED total: first aggregate every additive modifier - the
  weapon/spell pipeline (`getEffectiveOutgoingDamage`/
  `getEffectiveSpellDamage`: gear, effects, converted momentum) plus any
  skill-specific additive bonus (Impale/Skewer's doubled momentum rider
  rides INSIDE the multiplier) - THEN multiply. Never scale the raw
  weapon/spell number and add modifiers after. The shared 1.5x helper is
  `skill_helpers.damageTimesOneAndAHalf` (Skewer's 2x is a one-off). Split
  payload multiplications (Bash/Powerful Shot/Shockwave's collision damage
  = half the effective total) already satisfy the rule, and Charged Bolt's
  momentum ×3 is order-invariant (it multiplies a single modifier, not the
  total).
- **One top-level event per player action (orchestrator convention).** Each
  player input (`handleIdleInput`) pushes exactly ONE top-level event; if the
  action needs several verbs, the event is an orchestrator whose handler
  pushes them (e.g. `player_move_action` -> `player_turn_attack` +
  `clear_highlights` + `move_entity`). This keeps the recorded `event_history`
  one-entry-per-action so a loaded session derives idle points purely from
  VIRTUAL STACK DEPTH during reconstruction (see `replayToWithIdleTracking` in
  state.zig): sibling batches can't be distinguished from drains in the flat
  stream, so they must funnel through a single orchestrator. Bonus: undo
  granularity matches a single click/key. Orchestrators carry only the
  player's intent; all mutation is in the verbs they push.
- **Frame-level player actions (a RESTRICTED exception - do not extend
  casually).** The convention above rests on a contract the undo system
  depends on: EVERY player action is initiated from inside `update()`
  (handleIdleInput / handleAnytimeInput), so frame()'s two idle-point
  detectors (the drain loop's stack-emptied check + the idle update's
  `events_processed` check) always notice the drain finish and record the
  undo stop. The ONE case that may break this contract: an action that
  must resolve EXACTLY ONCE PER FRAME regardless of drain state - because
  `update()` re-runs per drain iteration with the same `PlayerInput` copy,
  an action initiated there multi-fires during a drain. Such an action is
  initiated in `frame()` before the drain (today exactly one exists: the
  text-field keyboard resolution - Enter/Escape - via
  `resolveTextEditOutcome`; see UI Framework → Text input widget). It
  STILL goes through the normal event pair (player wrapper → machinery
  event, `pushPlayerActionAndDrain` - never a direct GameState mutation)
  AND must record its own idle point with the action
  (`maybeRecordIdlePoint(true)` after the drain - its guards make that
  idempotent at every call site; without it, undo steps past the action
  and discards it from the future timeline - the bug this rule was
  written after). Adding another frame-level action requires the same
  once-per-frame proof AND the same recording; if it can run inside
  update() instead, it MUST. If a second one ever lands, extract a
  shared push-and-record helper so the idle-point step can't be forgotten
  (tracked in TODO → Tech Debt).
- **A player action that would change nothing never fires.** Every recorded
  player action creates an idle point; one that no-ops leaves an undo step
  (and a future replay step) that visibly does nothing. The input layer
  therefore gates every fire site on a would-change check, and the check is
  never ad-hoc duplication - it reuses the same pure predicates the handlers
  guard with (or, for the editor, one planner both sides consume). Landed
  gates: the editor click planners (see Level Editor → Active-tool model),
  the prepared-skill same-slot toggle (`resolveSkillSlotAction` →
  `.unprepare`), `dragActionWouldChange` + `salvageRegionOccupiedSlots` for
  the drag/inventory family, and the hub own-tile / NPC-tile /
  both-empty-hands swap gates. Handlers keep their graceful no-op returns for
  crafted or pre-change session logs (a redundant event in a log replays
  harmlessly).
- Arena allocation for game state snapshots/checkpoints. Deep copy via comptime reflection
- Allocator model (all on `GameStateHistory`, see state.zig): `backing_allocator`
  is the gpa backing every arena. Two live lifetimes: `history_arena` - durable,
  unbounded, backs the append-only session log (`event_history` + `idle_points`)
  and holds deep-copied event payloads (event slices are the replay source of
  truth, so they must outlive `current_arena` resets); `current_arena` - owns
  all memory referenced by `current_state`, compacted at each idle point
  (`compactCurrentArena`: deepCopy into a fresh arena, free the old) so per-turn
  churn and exited levels/hubs are reclaimed. `processEvent` and the input
  handlers get their state allocator from `current_arena`; durable recording
  goes through `history.recordEvent` into `history_arena`. Never allocate live
  gameplay state into the gpa directly - it won't be reclaimed or replayed.
- **The transient-lifetime invariant: NOTHING that survives a frame may
  hold a slice into the frame arena.** `main.frame` resets
  `frame_arena` every render; any object that outlives that reset
  (InputState's held keys, `previous_view_state`, the observability
  stash) dangles if it retains frame-arena bytes. The GameState/event
  boundary already enforces string ownership rigorously (deep-copied
  event payloads, the allocator model above) - the invariant extends
  the same discipline to the TRANSIENT seams where state crosses
  frames. Three instances found in one session (each its own DONE
  entry): console-merged input ids (fixed by INTERNING to static
  producible-id literals), the sprite picker's mission-cell ids (fixed
  by MINTING at the scan - session-owned bytes instead of a per-frame
  view mint), and the observability stash (safe wholesale copy BECAUSE
  of the scan mint). The pattern for new transient seams: borrowed
  strings must point at static literals, session-owned memory, or be
  copied - never at frame-arena bytes.
- Screen enum is authoritative for "where are we" - transitionScreen() handles cleanup
- PlayerData is persistent, Entity is the in-level/hub working copy. Synced via build_player_from_data / build_data_from_player events
- Player is always entity index 0
- SkillId/EffectId are comptime enums generated by build.zig from file names
- CampaignId/HubId/MissionId are runtime strings (folder names)
- Mid-turn equipment/skill changes must re-apply their side effects: boots
  change → recompute reachable tiles (`refreshMoveHighlights`); weapon change
  (swap or equip) → cancel any prepared skill (`cancelPreparedSkill`), since it
  rewrites the first three skill slots. Gear equip/unequip routes both through
  `applyGearChangeSideEffects`
- `end_level` / `end_hub` are the mandatory "leaving" lifecycle events and own
  the entity->PlayerData sync (they push `build_data_from_player{0}` on top,
  which runs while the old world is still live - before `start_level`/
  `start_mission` replaces it). Every path that leaves a level/hub MUST route
  through them, or entity changes (gear/inventory picked up in the world) are
  lost. Reverse direction (`build_player_from_data`) is pushed by `start_level`/
  `start_hub` after loading. (Note: `end_hub` used to be a no-op; the hub
  mission-exit path now pushes it before `start_mission`.)
- Gear operations use the `GearSlot` enum (types.zig). `equip_item` no-ops on
  type mismatch; `unequip_item` moves into an empty inventory slot, swaps on a
  matching filled slot, and no-ops on mismatch
- `equipped_utility_skills` is `[utility_skill_count]?SkillId` (nullable slots).
  Save format keys each filled slot by number (`slot_4`..`slot_8`); empty slots
  are omitted and reload to null - never compact/reindex on load. The skill
  bar never holds duplicate utility skills: the `player_assign_utility_skill`
  handler searches `equipped_utility_skills` for the dragged skill and, if
  found in another slot, pushes `swap_utility_skills` (target ↔ existing)
  instead of `equip_utility_skill` (which would create a second copy); a drop
  onto the slot that already holds the skill is a no-op. Weapon skills
  (slots 1-3, derived from the equipped weapon) are a separate,
  non-overlapping set in shipped content, so the search is over utility slots
  only. Replay-safe by construction (the check reads GameState, which
  reconstructs identically on replay). Save loading does NOT deduplicate - a
  hand-edited / pre-rule save with duplicates is preserved as-is (the rule is
  enforced at the drag path, the only way duplicates enter live). Dragging a
  skill OFF the bar (drop on empty space, a non-ref surface, or a cross-domain
  ref like an inventory slot) clears the source utility slot - see DESIGN →
  Architecture. A release back on the source slot is a no-op (no self-clear).
- Derived-from-entity data has a single source of truth: skill-bar slot
  resolution lives in `Entity.skillInSlot` / `Entity.collectSkillSlots`, not
  duplicated per caller
- **Cooldown inheritance on skill/weapon swap.** Equipping a skill or
  weapon onto the bar sets the incoming skill cooldowns to `@max(outgoing,
  incoming)` - never lower, so a fresh swap can't bypass a cooldown that
  was ticking on the displaced skill. This is what restricts the player to
  their 5 equipped utility skills at a time: rotating a used skill out and
  a fresh one in doesn't reset the used one, and rotating it back in
  inherits its preserved (still-ticking) cooldown. Two sites:
  `equip_utility_skill` - the incoming skill's cd becomes
  `@max(old slot skill cd, incoming cd)`. The outgoing skill's cooldown is
  PRESERVED in `skill_cooldowns` (not cleared) - clearing it would reopen
  the cycle exploit (use A, swap out, swap back in, use again). Since
  `skill_cooldowns` is keyed by SkillId (not slot) and `turn_start`
  decrements every SkillId's cooldown (not just equipped ones), a
  preserved cd keeps ticking while the skill sits off the bar.
  `equip_item` (main_hand/off_hand) - `transferWeaponCooldowns` sets all
  THREE of the new weapon's skill cds to `@max(old weapon's corresponding
  cd, new weapon's corresponding cd)`, even though only slots 1-2 (main)
  or slot 3 (off) are exposed for that hand. The hidden skill's cd is set
  anyway and surfaces later if the player `swap_hands`. Both old+new cds
  are snapshotted before any `set` so a degenerate SkillId overlap between
  weapon types can't double-decrement. No new event or session-log field:
  cooldowns are entity state mutated directly in the handler (same shape
  as `applyGearChangeSideEffects` clamping health), replay-safe by
  construction. Deliberately NOT applied to: `swap_utility_skills` (both
  skills already on the bar, cds travel by SkillId), `unequip_utility_skill`
  / `unequip_item` (no incoming skill to inherit), and `swap_hands`
  (changes which skills are accessible, not which are equipped - a used
  skill stays on cd when it reappears in the other hand, no bypass).
- `current.level.?` (and similar) force-unwraps in level/sub-level event
  handlers are intentional invariant assertions (those events only run in a
  level; the event stack is cleared on screen transition). Prefer fail-fast
  over silently returning, which would hide the logic bug the unwrap catches

### Modal overlays (pause + shield pattern)

**The z-order ladder** - the canonical emission shape in `view()` (painter
order = draw order; later block = on top). The stackable modal overlays
emit in OPEN order - the overlay stack (`UiSurfaceState.open_overlays`)
walked bottom-up - so ANY overlay opens on top of any other (the world
map over the options menu, tips over the map, settings over the
browser); the last opened draws on top. The z-order census test in
view.zig pins the DYNAMIC property (forced frames in deliberately
canonical-defying open orders), so a regression to any fixed emission
order fails the build:

1. Base per-screen UI (world, bottom bar / editor shell / main menu)
2. Drag ghost (mid-drag only - no modal is reachable then)
3. The overlay stack, in open order: options menu, load-save browser,
   credits, tips, settings screen, editor browser, world map, full
   combat log - whichever order they were opened in
4. Mission-fail overlay, then mission-complete / validation stats (the
   announcements, fixed ABOVE the stack - death/completion take
   precedence over anything the player had open; complete above fail is
   the pinned never-co-rendered order)
5. Error popup (the most-modal surface)
6. Global top bar (options/undo/redo/tips `?` - clickable above every
   modal by design)
7. Hover tooltip (passive, non-blocking)
8. FPS diagnostic label (non-blocking; spatially below the top bar)

The full combat log has no view yet (and no open path); when it lands it
joins the stack like every other overlay - the dispatch loop in view() is
the seam.

**The toggle verb is raise-or-close** (taskbar-button semantics): a
surface's toggle (keybind, top-bar button, menu button - all the
`player_toggle_ui_surface` paths) OPENS it on top when closed, RAISES it
to the top when open but covered (remove + re-append), and closes it
only when it is the topmost. The top bar stays clickable above every
overlay, so a covered surface's icon reads as "bring to front" and must
behave like it - toggling the hidden copy closed invisibly behind
whatever covers it was the wart that motivated the semantics. Back
buttons + Escape are close paths and never raise (`close` / the
stack-pop rung).

Full-screen modal overlays - the options menu, the error popup, the
mission-fail overlay, the mission-complete overlay - share a structure:
`view()` builds them when a condition is true (a SessionState flag, a
GameState field, or `pending_error`), the full-screen 9-slice panel is
`blocks_input: true` so `hitTest` shields the UI behind it, and the overlay
buttons carry `Action`s that dispatch via `handleAnytimeInput` (before any
`update()` gate) so they work while the world is paused.

**What an open overlay blocks - and what it doesn't.** Every
full-screen overlay (`UiSurfaceState.anyOverlayOpen`) is a pause, not an
input vacuum, and they all pause identically (the options-menu rule
generalized): GAMEPLAY input (skill slots, swap weapons, drag/camera/
idle input) is gated, the animation clock + wait timer freeze, and events
already on the stack stay locked at their depth until the overlay closes.
UI navigation stays live - each overlay's own interactions via
`options_action` and the per-browser pre-gate blocks in
`handleAnytimeInput` (the load-save browser's rows/Back/Import ride the
anytime path too, drained to the stack baseline by
`pushPlayerActionAndDrain`), and the SURFACE toggles
(inventory/gear/skills/inspect/world-map keybinds) via their dispatch
hoisted above the pause gate. Any overlay can open on top of any other
(the stack model); Escape pops the topmost first. The gate is the pause
rule, not a z-order rule.

**Two rules, learned the hard way:**

1. **Don't gate `update()` before `processEvent` when the trigger is set
   inside an event handler.** The overlays and the error popup gate
   `update()` at the top (return early before `processEvent`) - that's safe
   because their triggers are set OUTSIDE the event drain: overlay
   toggles are in
   `handleAnytimeInput` (before the gate), and `pending_error` exits
   the drain via the `load_error` break (not via the gate). The mission
   overlays are different: their triggers are set INSIDE a handler
   (`end_level` sets `last_completed_mission`; the `attack` handler sets
   `player.health == 0` and pushes `death`). A top-of-`update()` gate would
   block the remaining cascade events from draining - the player gets stuck
   mid-transition, and the unprocessed event keeps `event_stack.len > 0` so
   the render gate's `drain_in_progress` skips `view()` entirely (no overlay,
   no sound). The mission overlays DON'T gate `update()`; they rely on the
   `blocks_input` panel + idle-input self-gating (idle input only runs in
   player turn phases; a dead player or a just-completed mission isn't in
   one). If a future modal's trigger is set inside a handler, don't gate -
   or gate only the idle-input/drag branch, not `processEvent`.

2. **Derive modal overlays from undoable state when possible, so undo/redo
   handles them naturally.** mission_fail derives from
   `level.entities[0].current_health == 0` (GameState) - undo restores
   health, the overlay vanishes. mission_complete derives from
   `last_completed_mission: ?MissionCompleteInfo` (GameState field, on the
   undo timeline) - the info rides the `end_level → end_mission → start_hub`
   cascade as an optional field on those events; `start_hub` sets the
   GameState field; Continue pushes a `dismiss_mission_complete` event that
   clears it (on the timeline - undo re-shows, redo dismisses). Both fall
   out of undo/redo without special-case cleanup. Contrast: a SessionState
   flag (off the timeline) survives undo and needs manual clearing - that
   was the first mission_complete implementation, and the overlay stayed
   open on undo. Prefer the GameState-derived approach when the trigger is
   already in undoable state.

### Level Editor (core + UI + save/export + editor browser landed)

A custom-mission editor. A mission is multiple sequential levels, so the
editor is focused on a mission with per-level tabs (quick swap to edit each
level) + a mission-shared palette of enemies/decorations. Lives on
`GameState.editor: ?Editor` - null outside the editor (populated by
`open_editor`) so normal gameplay snapshots pay nothing; when populated,
snapshots carry it (bounded ring, acceptable for now).

```zig
EntityTypeDef = struct { id: []const u8, template: Entity };  // palette entry (prefab)
DecorationTypeDef = struct { id, sprite, footprint };
EditorLevel = struct {                      // reference-based (not concrete Level)
    name, color_wheel_index, level_tiles, player_start: Vector2,  // the '!'
    level_end: ?Vector2,
    entity_placements: []EntityPlacement,     // (type_id, position) into palette
    decoration_placements: []DecorationPlacement,
};
Editor = struct {
    mission: Mission, levels: []EditorLevel,  // was []Level - now reference-based
    entity_types: []EntityTypeDef,             // palette (enemies)
    decoration_types: []DecorationTypeDef,
    player_def: EntityTypeDef,                 // editor-global player loadout (player.txt)
    active_level_index: usize = 0, mode: EditorMode = .edit,
};
EditorMode = enum { edit, playtest, validate };
```

`Screen.editor` is the screen; `editor.mode` is the modal switch within it.
Edit mode = editor UI/input; playtest/validate = gameplay UI/input with the
editor dormant (the "home base" you return to). No new Screen variants for
playtest/validate - they're gameplay using the existing gameplay input/UI,
just with editor-scoped exit flow. The `.editor` screen scope is just
`{ editor }` (NOT `level` - the editor reads `editor.levels[]`, not
`current.level`); the `.level` scope includes `editor` so the dormant editor
survives the playtest/validate screen transition.

**Palette: transient, dedup-on-load, no on-disk file.** On `open_editor`, the
levels' inline entity/decoration definitions are deduped into `entity_types` /
`decoration_types` (`entityDefinitionsEqual` compares definition fields only,
not runtime/position). Placements store `(type_id, position)`. Editing a type
updates every placement referencing it - no propagation sweep. Save flattens
back to the existing inline level format (single format, backwards
compatible). **Unused types are lost on editor close** (accepted as cleaner) -
since save is inline, a type with zero placements has no on-disk trace.

**Player loadout: `player.txt` in the mission directory, persistent.** The
player isn't part of the entity palette (it's not placed; the `!` in each
level's Layout is the spawn position, already parsed). The loadout persists
as `player.txt`, SAVE-SHAPED (the loadout sections of a player save -
MainHandWeapon / OffHandWeapon / Amulet / Coat / Gloves / Pants / Boots /
Inventory / UtilitySkills, `player_loadout_file_format_version` 2; NO
Info / stats / hubs / clones / UnlockedSkills - base stats aren't
authorable (the template keeps the Entity defaults) and learned is
implied for the editor player (see Playtest/validate framing). The
shared section parsing lives in `parsePlayerLoadoutFields`, reused by
`loadPlayerSave`; `loadPlayerLoadout` maps the result onto the template
via `playerLoadoutEntity` - the `build_player_from_data` field set).
Editor-global: same player across all
level playtests. Visible metadata (someone picking up a custom mission sees
the author's loadout). All official campaign missions ship a `player.txt`
(starter loadout) too.
**Load order (open_editor):** the mission's `player.txt` if present
(`error.FileNotFound` specifically - a present-but-corrupt file errors,
not silently replaced); a mission without one falls back to
`data/max_player.txt` - the MAXED DEFAULT, a full player save (the
future "start at endgame" option loads it as a save; fresh-mission
creation seeds `player_def` from it): the five armor slots
EQUIPPED at the `max_*` bounds, weapon slots + utility bar EMPTY,
Inventory = two of each weapon type at `max_weapon_damage`, every
utility skill learned, every hub in the campaign discovered.
In-campaign play of a custom mission uses the campaign's PlayerData instead
(separate path, doesn't change the editor design).

**Fresh missions + Mission identity (uuid).** A fresh-mission open
(the editor browser's / options menu's New Mission button, ctrl+N, or a
mission-browser row with no editor state yet) pushes `open_editor` with
a NULL `mission_path` →
"New Mission" at `missions/New Mission` (the persistent-dir-relative path
- anchors the sprite picker's mission-local scan + the `custom/<mission>/`
stem namespace; the dir usually doesn't exist yet, and the scan treats a
missing dir as empty), ONE default-template level
(`data/default_level.txt`), empty palettes, `player_def` from
`max_player.txt`. A non-null path opens that mission directory (an
editor browser row - see The editor browser) - the loading path is unchanged.

The fresh mission's uuid stays EMPTY for the whole editing session:
mission uuids are FILE CONTENT (authored in mission.txt), and identity is
minted when the file is born - at SAVE time (the save is an input-layer
side effect; replay never runs the input layer, so randomness is safe
there). The mint is WRITE-ONLY: the save writes the generated uuid into
mission.txt but never writes it back into GameState - a random value in
state would diverge from the replayed log on every replay
(`verifyReplayMatch` would catch it). Repeated saves keep the identity
stable through a SESSION-SCOPED MEMO (`SessionState.editor_saved_mission`
- the uuid + dir of this session's last save, the side-effect scratchpad,
off GameState and off the timeline): a re-save reuses the memo's uuid
instead of minting again. The uuid enters state only when a mission is
LOADED from disk. Nothing in an editor session needs it meanwhile (the
only runtime consumer is the clone keying in the end_mission /
mission-complete paths, which the editor's exit guard redirects to
end_playtest/end_validation before they run).

**The save/export flow (LANDED).** The save target is ALWAYS derived as
`missions/<uuid>_<sanitized name>/` (uuid first; path-hostile name
characters → '_', empty → "Unnamed") - which gives the rename semantics
for free: a re-save of an unchanged custom mission lands in the same dir,
a RENAMED mission lands in a NEW dir (the old one stays behind), and an
OFFICIAL mission opened for editing saves as a FORK - a fresh standalone
identity in `missions/`, never the official uuid (the official campaign's
mission table, clone records, and leaderboard keys stay the original's;
the origin rule lives in Campaigns & the Campaign Editor → Rename + Save
As Copy). The save
is the dump_event_log class - a pure input-layer side effect with NO
recorded event (there is no GameState component, so an event would mint
dead undo steps; replay never runs the input layer so it never re-fires):
ctrl+S (a shipped binding) + the editor options menu's Save Mission
button. The WRITER is pure (`writers.writeEditorMission` - mission.txt /
player.txt / level_N.txt; the projection is directly round-trip-tested
through buildEditorMission). Per level: the layout is TRANSLATED to its
bounding box (each row trimmed to its own last used column - no wasted
edge space; positions shift accordingly on reload) and tools get
PER-LEVEL layout char codes (only the tools that level places get a
definition; codes assigned in palette order from digits → lowercase →
uppercase → remaining printable ASCII, `!` `.` `=` space reserved; a
level exceeding the 91-code set fails the write with a popup). Enemy/item
chars imply their tile on reload; decoration anchors take no tile.
**The save carries the mission's custom art + heals stale stem
namespaces (the single-dir rule - see the Sprite id convention):** the
writer normalizes every `custom/<anything>/<file-stem>` to the save
target's namespace (`custom/<uuid>_<name>/<file-stem>` - the dir
component is identity-only, so the save target is the truth; the
in-memory Editor state is NOT touched, keeping the side effect
replay-safe), and the save copies every REFERENCED custom PNG (entity +
decoration palette types, base + layers - referenced art only, not the
whole old dir) into the target dir. Source: the mission's current dir
first, then the stem's embedded namespace (legacy pre-rename content -
a one-time migration read; a missing source is skipped, it already
warned at load). Consequence: a RENAMED mission re-save lands in a new
dir WITH its art + healed stems - the old dir becomes deletable, and
exports of renamed missions are self-contained (the zip bundles the
saved dir). A stem rewrite changes content identity - the validation
replay re-binds via Revalidate as usual.
The
EXPORT (the options menu's Export Mission button) saves first, then
bundles the saved configs + the mission dir's custom sprites + a
validation_replay.txt (once validation writes one) into a STORE-method
zip (`zip_writer.zig`) at `exported_missions/<uuid>_<name>.zip` - on web
the file is also offered as a browser download (the Export Save seam).

**The editor browser (LANDED).** One full-screen modal is the editor
front door - browsing AND creating editor content - from both the main
menu (the Editor button) and inside the editor (the options menu's Open
Mission button + ctrl+O); the Back button closes it (all three toggle
`Action.toggle_editor_browser` → the recorded `player_toggle_ui_surface`
(`GameState.ui_surfaces.isSurfaceOpen(.editor_browser)`; Escape
steps back one layer, the options menu it opened from stays beneath).
The window is TABBED PER EDITOR KIND - the plan is TWO editors
(missions + the campaign editor, which contains hub editing - see
Campaigns & the Campaign Editor) and only the mission editor exists,
so the tab row shows one tab; a kind appears as a tab only when its
editor lands (the specs list derives from `types.EditorKind` at
comptime; the exhaustive label switches are the compile error until a
new kind is named + routed). A single NEW button derives from the
ACTIVE kind ("New Mission", firing the same recorded `open_editor{null}`
as ctrl+N) - not one button per tab: buttons for content that isn't on
screen would be dead buttons. Per-kind content lives behind an
exhaustive switch; the mission content keeps the original browser
shape - two tabs at the top (the sprite picker's tab pattern):
**Your Missions** (`FileSource.listMissions` - the persistent `missions/`
dir, where editor saves land) and **Official** (`FileSource.listOfficialMissions`
- the shipped embedded campaign missions, comptime path list + runtime
metadata parse, scanned once per session). The LOCAL tab is sorted NEWEST
FIRST: each entry's sort key is the max mtime across the mission folder's
files (any change - editor save, custom png, validation replay - counts
as an update; `MissionEntry.mtime_ns`), name ascending breaks mtime ties
(the load-save browser's ordering, scanned in sorted at `listMissions`
time). The OFFICIAL tab keeps its comptime path order (embedded content
has no filesystem). Lists live on SessionState
(scanned from the input path on open, never `view()`; no periodic rescan
while open - nothing can add a local mission while the modal is up, a web
import rescans explicitly). The per-mission probe + parse + the folder
scan run the same `Dir.iterate` path on every platform (the old
IDBFS-era platform split - a JS listing via a temp file because the
IDBFS mount's readdir was broken - died with the IDBFS mount itself;
see DONE.md "web storage model slice 5"). A row click pushes
the ordinary `open_editor`
with the row's path (`pushPlayerActionAndDrain`) - the loading path is
unchanged; replay re-reads the files silently (the `player_load_save`
shape). Three settled points:
- **No unsaved-changes confirm** - opening replaces the mission being
  edited; save first if in doubt (ctrl+S is cheap). Deliberate.
- **`open_editor` bumps `world_generation`** in BOTH branches: the
  driver's transition UI reset fires on screen-change OR generation-bump,
  and an editor→editor open changes neither screen - without the bump the
  stale classes-2-4 view state (scroll offsets, in-progress edits) would
  survive the mission swap (the class-1 surface state closes via
  transitionScreen, which open_editor's handler reaches). On a failed open
  the revert restores the generation, no reset fires, the browser stays
  open + the popup surfaces (exactly the load-save browser's failure
  shape).
- **Undo across the swap works** - `open_editor` is on the timeline, so
  undo restores the previously-edited mission. Accepted as a feature.

**The fresh-mission open (New Mission - LANDED).** The browser's New
Mission button, the options menu's New Mission button (+ ctrl+N, the
`new_editor_mission` action - editor-context only: the New pair is
SPLIT by editor screen, ctrl+N on the campaign editor fires the
campaign sibling `new_editor_campaign`) fire `open_editor` with a null path,
consumed in the anytime block behind the editor + main-menu gate
(`editorBrowserReachableScreen` - every other screen no-ops, the
save_editor_mission discipline; the keybind ships editor-context, so on
the main menu only the button path fires).
It's a RECORDED player action (`pushPlayerActionAndDrain`), so the three
settled points above apply verbatim: no unsaved-changes confirm, the
world_generation bump closes the options menu / browser / pickers over
the swap, and undo restores the previously-edited mission. The fresh
mission is the open_editor-null shape: "New Mission", one template
level, no uuid (minted at save time).

**The zip import (LANDED).** The browser's web-only Import button (also
ctrl+I) opens a file picker; the picked `.zip` lands in
`imported_missions/` + writes `.mission_import_marker` (the save import's
marker pattern), and the Zig-side poll (while the browser is open) extracts
it into `missions/` + rescans so the row appears immediately. Design
points:
- **`zip_reader.zig`** (the sibling of zip_writer): buffer-based central-
  directory walk accepting STORE (our exports) + DEFLATE (any OS
  "compress" default - inflate via std.compress.flate), CRC-verified;
  zip64/encryption/other methods rejected with descriptive errors.
- **Extraction is validation-before-write, headers-first**: every cap
  + every name is checked over the central-directory headers BEFORE any
  entry is decoded - the count (1,024), per-entry (64 MB), and total
  (256 MB, coherent with the zip-bytes read limit) caps close the
  hostile-declared-uncompressed-size memory bomb (extraction allocates
  the declared size upfront, so a cap that runs after it is too late;
  the pass structure mirrors `importGameFolder`). Junk entries (directory
  markers, `__MACOSX/`, `._*`, `.DS_Store`) are skipped, a single common
  root folder is stripped (the OS-compress shape), and every remaining
  name is checked (no absolute paths, no `..` traversal, no backslashes,
  no empty segments) BEFORE the first file is written - a hostile or
  malformed zip fails whole with the popup, never half-imported. Entries
  decode one at a time through a per-entry reset arena (memory stays at
  one entry through the whole import).
- **The target dir is the save convention** `missions/<uuid>_<sanitized
  name>/` (uuid + name parsed from the zip's mission.txt; no uuid →
  `missions/<sanitized name>/`) - re-importing the same zip overwrites
  the same dir, idempotent. The zip is deleted on success (the extracted
  folder is the artifact) and kept on failure (re-uploadable).
- **Native has no Import button** - drop the extracted folder into the
  persistent `missions/` dir by hand; the extraction path itself is
  platform-neutral and tested natively by writing the zip + marker
  directly.

**Editor edits ride the existing event system.** `EditorEvent` variants
(`editor_set_active_level`, ...) mutate `current.editor.?.levels[level_index]`
or the palette directly - pure state transforms captured by `deepCopy`, so
undo/redo works by construction. No editor-specific undo machinery. Editor
save-to-disk is a side effect gated on `!replaying` (same convention as
`save_game` / `dump_event_log`) - files stay off the undo timeline.

**Playtest/validate framing (Option 2: separate framing events, minimal
exit guard).** `open_editor` / `close_editor` / `start_playtest` /
`end_playtest` / `start_validation` / `end_validation` are MetaEvents. They
own enter/exit; the gameplay events stay pristine. `start_playtest` calls
`instantiateEditorLevel(editor, N)` → a concrete `Level` (entity 0 from
`player_def` at `player_start`, each enemy from its palette type at its
placement, runtime fields reset - EXCEPT the player's INVENTORY, which is
loadout data (imported or authored), not a combat-runtime field: entity 0
keeps `player_def.template.inventory`), copies `editor.mission` → `current.mission`
(so gameplay handlers read unmodified), preserves the editor mode (only flips
to `.playtest` when entering from `.edit`), transitions to `.level`,
and pushes `pushGameplayStartEvents(sync_player=false)` - **the player sync is
skipped** because the player is already fully instantiated from `player_def`
(normal gameplay's `build_player_from_data` would clobber it with the
campaign's PlayerData). **Playtest player_data (dormancy).** In-level
events (`use_skill_tome`, skill-tome salvage) read + mutate
`current.player_data` DIRECTLY, so a run can't share the session's real
data: on ENTER (only at `start_playtest` from `.edit` and at
`start_validation` - the chained `start_level`s of a validation run don't
touch the backup, and the restart re-entry's fresh `start_validation`
re-backs-up AFTER the inline teardown restored the real data) the real
data is backed up onto the Editor
(`Editor.pre_playtest_player_data`, on the undo timeline) and the run's
is BUILT from the loadout - `player_def`'s for playtest, the SAVED
`player.txt`'s for validation - via
EVERY utility skill (implied, never authored in player.txt): the editor
player knows everything, so tome pickups read already-learned and any
learned-gated path is permissive. `end_playtest` / `end_validation`
restore the backup (null = the fresh-session default) and clear it.
`end_playtest` / `end_validation` discard
`current.level` + `current.mission` (discard semantics - playtest/validate
never write back to the editor's levels) and restore `screen = .editor`,
`mode = .edit`. **Playtest and validation DIVERGE in their run source**
(settled with the validation-replay design - DESIGN → Custom Missions &
Online Services → Validation replay): playtest instantiates from the LIVE
editor memory (quick iteration on the draft - the `start_playtest` path
above, unchanged); validation runs the SAVED ARTIFACT.
`player_start_validation` carries `mission_path` - the input layer saves
the mission first (the editor-save flow; a failed save surfaces its popup
and aborts without starting) and pushes the saved dir's path.
`start_validation` is the `start_mission` shape: it reads `mission.txt` +
`player.txt` from that dir via the reconstruction cache, builds the run's
player data from the FILE loadout (`buildPlaytestPlayerData`,
all-skills-learned), sets `current.mission` from the files, and pushes
`start_level{path, 1}`. The per-level continuation is the campaign's own
next-`start_level` chaining (turns accumulate across levels on
`current.mission`, exactly like campaign play); the last level pushes
`end_validation{success=true}` instead of the `end_mission` cascade.
`end_validation` has a null-editor branch: live (editor present) it
restores + returns to `.editor`; in cross-session replay of a validation
replay there is no editor - restore nothing, transition to the main menu.
Validation certifies the shipped FILES, not the editor memory: the save's
bounding-box translation, palette dedup, and any writer bug make file ≠
memory, so running from files doubles as a round-trip test of the writer
(a save bug fails validation before upload).

**Exit guard (the minimal editor-aware seam).** `end_level` checks
`current.editor`. In `.playtest`: a RESTART continuation re-runs the level
fresh - the run's teardown happens INLINE (restore the real player data +
`mode = .edit`, NO transition: `transitionScreen` clears the event stack,
so an `end_playtest` + queued re-entry pair can't ride the stack) followed
by a fresh `start_playtest` on the same level, which takes the normal
enter-from-edit path (backup + rebuild from `player_def`); any other exit
(natural completion or Exit Playtest/Validation) pushes `end_playtest`. In
`.validate`: restart does the same inline teardown + re-entry via the
ORCHESTRATOR `player_start_validation{mission_path}` (not the machinery
event - every attempt must begin with a seedable top-level player action
for the validation-replay slice; see DESIGN → Custom Missions & Online
Services → Validation replay); an Exit Mission continuation ABORTS the
run (`end_validation{success=false}` - only successful runs write a
replay); the default continuation is the campaign's own
next-`start_level` push (file-based, cache-read) or, on the last level,
`end_validation{success=true}`. In BOTH modes an
Exit-to-Main-Menu continuation tears down inline (same transitionScreen
constraint - and the restore must precede `close_editor`, whose scope swap
discards the Editor carrying the backup) and chains `close_editor`: the
button means the MAIN MENU, not the editor. `build_data_from_player`
is skipped in editor mode (playtest/validate are discard-semantics - the
player's real PlayerData is unchanged). `end_mission` also guards: if an
editor is active, suppress the `start_hub` continuation (defensive -
`end_level`'s guard should redirect before `end_mission` is ever reached).
No other gameplay handler knows about the editor.

**Run-context UI (options menu + mission-fail overlay).** While a run is
active, both surfaces label their restart/exit buttons for the RUN
("Restart Playtest" / "Exit Playtest", or the Validation nouns) instead of
the mission, and the campaign Export Save button is HIDDEN in the options
menu - the run's `player_data` is temporary (rebuilt from the editor
loadout, discarded on exit), so an export mid-run would write throwaway
data as a campaign save. `save_game` is button-only, so hiding the button
removes the path entirely. The menu's Exit to Main Menu button keeps its
label during a run and is truthful: it ends the run + closes the editor
(see the exit guard above).

**Replay & the reconstruction cache.** `open_editor` (the path-open
branch) reads mission.txt +
player.txt + all level_N.txt via `readReconstructionFile` (cache-deterministic).
`buildEditorMission` (pure, no I/O) does the dedup. In-memory instantiation
(`start_playtest` calling `instantiateEditorLevel`) is an event mutating
`GameState` - captured by `deepCopy`, deterministic by construction, no cache
concern.

**Editor UI layout (settled design; landed in slices).** Three-zone
layout + a left inspector + a right metadata sidebar:

```
┌──────────────────────────────────────────────────────────────────┐
│ [Level 1] [Level 2] [Level 3]⟷ [+]                  [Test][Validate] │  tabs + primary actions
├──────────────┬────────────────────────────────────┬──────────────┤
│              │                                    │   Settings   │
│  Inspector   │           Level Viewport           │   (right     │
│  (left bar,  │      (rendered as in-game;         │    bar,      │
│   toggleable)│       clickable for paint/         │    toggle-   │
│              │       place/select)                │    able)     │
│              │                                    │              │
├──────────────┴────────────────────────────────────┴──────────────┤
│ [Select][Tile] [Entities ▾] [Decorations ▾] [Items ▾] ⟷           │  tool palette (bottom bar)
└──────────────────────────────────────────────────────────────────┘
```

- **Tabs (top):** one per level, horizontally scrollable when too many
  for the width (LANDED): the row is bounded on the right by the
  primary-actions block; overflowing tabs show through a scroll window -
  one wheel notch over the tab strip = one tab (`UiState.editor_level_tab_scroll`,
  the palette window model; the builder clamps the upper bound authoritatively)
  and, when the ACTIVE TAB CHANGES, scrolls the minimum distance to bring it
  on-screen (the add-level flow's switch-to-new-tab lands visible) - a
  change-less frame never touches the offset, or the follow would fight
  every manual scroll. Each tab
  carries a close button (×) - the shared
  `ui/close_button` class, flush in the tab's top-right corner - that
  deletes the level (`player_delete_editor_level` → `editor_delete_level`:
  order-preserving removal, later levels shift down, `mission.level_count`
  syncs to `levels.len`, and the active tab adjusts - a delete below it
  shifts it down, deleting the ACTIVE level clamps + clears the selection,
  the `editor_set_active_level` semantics). Offered only while the mission
  has >1 level (a mission always has ≥1 - the handler PANICS on the
  violated invariant; the UI, the input layer, and `validatePlayerAction`
  all gate it first). The "add level" button (`+`)
  is pinned flush at the row's right edge (one `ui_gap` clear of the
  primary-actions block) so it's always reachable while the window
  scrolls; it creates
  a level from the default template (`data/default_level.txt` - a minimal
  `!=` layout, `!` at (0,0), `=` at (1,0); the markers carry their own
  ground, so exactly those two tiles; unnamed - the author renames via the
  metadata sidebar) via `editor_add_level`, read through the
  reconstruction cache, and SWITCHES TO the new level (the author lands on
  the thing they just created). Tab label: the level's name or "Level N" if
  unnamed; a color swatch from `color_wheel_index`.
- **Level viewport (center):** the active level rendered as in-game (tiles,
  decorations, entities, ground items, `!`, `=`). Click behavior is FULLY
  MODAL on the active tool (see below) - no dialogs, no mode-switching
  prompts; the active tool determines what a viewport click does.
- **Tool palette (bottom bar):** mirrors the in-game bottom bar's slot
  style. Fixed tools first ([Select] [Tile]), then three collapsible groups:
  Entities, Decorations, Items. Keyboard: Digit1 = select tool, Digit2 =
  tile tool, Digit3/4/5 = expand/collapse the entity/decoration/item groups
  (context-`editor` bindings - the same keys are the in-game skill slots;
  see DESIGN → Input → Binding contexts). The keybinds are payload-less
  actions (`editor_select_tool` etc.) bridged in `translateInput` onto the
  click paths' `options_action` + payload pairs, so the tool-cell and
  group-header consumption sites serve clicks and keys identically (the
  tool switch rides the undo timeline; the group toggle is the accordion
  UiState write). Each group shows at most 8 type
  cells (the visible window); scrolling the wheel with the pointer over a
  group shifts its window left/right (one cell per notch; state on
  `UiState.editor_palette_scroll`, clamped in the builder). Each slot
  renders the type's graphic on the shared `ui/button_background`
  (aspect-preserved, centered) - entity + decoration cells render the
  type's FULL scene composition (entities: base + layers + weapons, the
  off-hand mirrored, weapons suppressed when `displays_weapons` is
  false; decorations: base + layers), every stack member at the SAME
  fitted rect and tinted exactly as the scene composes it (see DESIGN →
  Entity & UI Coloring), so the palette preview matches what a placement
  looks like in the viewport, with a small close-button
  (`ui/close_button`, the shared close class) flush in the cell's
  top-right corner: clicking it deletes the type AND every placement
  referencing it across ALL levels (`player_delete_editor_type` →
  `editor_delete_type`; one undo step restores everything - the active
  tool resets to select when it pointed at the deleted type, and higher
  same-kind tool/placement indices decrement with the palette shift). Each group has an "add new" button (`+`)
  at its tail that appends a new type built from the SHIPPED DEFAULTS
  (`data/editor_defaults.txt` - one entry per kind in the level-file
  section formats; the decoration default duplicates the stone_1 prefab)
  via an `editor_add_*_type` event; the same handler makes the new type
  the active tool + opens the inspector, and the input layer opens the
  base-sprite picker on it for enemies + decorations (items have no
  sprite to pick). One undo step reverts the whole creation. The `+` and
  the group header stay fixed while the window scrolls.
  An EXPANDED group's header + `+` sit in the strip above the bar
  (labeling the cells below); a COLLAPSED (or empty) group's header + `+`
  drop flush against the bottom of the screen - visible content to
  expand, not a floating orphan. The `+` cells (palette + the add-level
  one below) are square `ui/panel` cells, the level-tab visual class.
  Hover tooltips on slots show the type's name.
- **Inspector (left bar):** shows TYPE fields for the currently-relevant
  type (see selection model). User-toggleable via a top-left "Inspector"
  button flush below the options button (the level-tab / group-header
  visual class: panel-backed, 128 high), open by default; the button is
  highlighted while open. The open flag lives on the Editor
  (`Editor.inspector_open`) and flips via `editor_toggle_inspector` - on
  the undo timeline, per the general UI state classification (all
  class-1 surface state is event-driven GameState - see UI Framework);
  unlike the palette accordion (classes 2-4, a UiState write), the
  auto-open-on-creation behavior below mutates it from the
  `editor_add_*_type` handlers (handler purity - events can't write
  session-side UiState), and replay must reproduce
  it. (Unifying the in-game panel toggles onto this GameState convention
  is a tracked TODO.) The background panel (width 1024, a placeholder
  until the field layout settles) spans from below the button down to
  one `ui_gap` above the palette groups' header strip (the bottom bar is
  flush left, so an expanded group's header x-range overlaps the panel -
  the gap keeps them visually separate). Auto-opens on new
  entity/decoration/item creation (the author lands on the new type's
  fields immediately). Field editing is inline within the inspector: skill
  assignment, gear equip, stat fields, footprint editing (decorations),
  etc. Base-sprite selection is the one exception - it goes through the
  centered sprite picker (below); decoration layers added via the
  inspector pick their sprite through the picker the same way. The
  panel scrolls: the wheel over it shifts `UiState.editor_inspector_scroll`
  (clamped in the builder), and only rows fitting the panel height are
  emitted (offscreen rows can't be clicked). Every SECTION HEADER is
  clickable - expand/collapse that section (a +/- marker prefix carries
  the state); ALL COLLAPSED by default (the panel starts minimal),
  INDEPENDENT toggles (no accordion - sections are per-topic, Weapons +
  Gear often wanted together). Collapse is a view affordance:
  `UiState.editor_inspector_section_expanded`, keyed by
  `EditorInspectorSectionId` (shared across the enemy + player contents -
  Weapons expanded on an enemy stays expanded on the player), a direct
  UiState write off the undo timeline (the palette-accordion class, NOT
  the one-at-a-time behavior). The section-break SPACER belongs to the
  section above it - a collapsed section takes no gap after it (headers
  stack flush).
- **Inspector fields (entity types - settled):** the COUPLING CONTRACT is
  the parser: every key `parseEntityDefinition` reads maps to exactly
  one inspector control, and field bounds are single-sourced from the
  `max_*` constants in loaders.zig (the parser's clamp and the UI's
  commit-time clamp read the same constants - a bound can't exist in
  one place only). Event routing: one thin `PlayerInputEvent` wrapper
  per field verb → the existing `editor_set_entity_*` EditorEvent (the
  orchestrator convention; the replay whitelist requires a
  PlayerInputEvent at the top of every stack - see Determinism &
  Tiebreaking). Controls per field:
  - name: a text input (see UI Framework → Text input widget). sprite
    id: the centered sprite picker (LANDED - the interim v1 text field
    is gone); the Mission tab takes priority over Official (custom
    assets over shipped ones) - see the centered sprite picker below.
  - color_index: inline swatch row (the settings screen's 6-swatch
    player-color row is the precedent) - not a picker.
  - displays_weapons: toggle.
  - base stats (max_health, defense, speed, aggro_range): numeric text
    inputs, UNBOUNDED by design - gear bounds exist for player-pickup
    balance (the player acquires exactly those items), while enemies
    are deliberately allowed to be as unbalanced as the author wants;
    validation guarantees a level is completable either way. momentum
    is NOT authorable (a transient combat stat, every entity starts 0
    - a level file can't set it; `editor_set_entity_momentum` was
    removed for exactly this).
  - weapons (main/off hand, nullable): the 6 weapon types as an INLINE
    row - picking a type while the slot is null CREATES a default
    weapon of that type (name "New <Type>", damage 0); picking another
    type while present RETYPES in place (name/damage kept); a Delete
    button clears the slot to null. weapon_damage: numeric input
    clamped to `max_weapon_damage`.
  - other gear (amulet/coat/gloves/pants/boots, nullable): Add creates
    a default item, Delete clears to null; per-stat numeric inputs
    clamped to the gear `max_*` constants.
  - utility skills (slot_4..slot_8, nullable): ONE row of five 128×128
    skill slots (the entity-inspect look: skill-button frame + full-size
    icon; the `ui/skill_slot_empty` diamond when null), each opening the
    centered picker (below) - it is the picker framework's first
    consumer. The row emitter takes the team gradient as a parameter, so
    the enemy + player inspectors share it. Only UTILITY
    skills (spells, cantrips, enchantments, curses - never weapon
    skills, which belong to the equipped weapon) may sit on the bar:
    the picker never offers them, the parser warns + drops them from
    slot_4..8 (entity definitions AND player saves), a weapon-skill
    TOME is dropped entirely, and the player equip path gates the same
    way (src/utility_skills.zig is the single source). The picker is a
    DROPDOWN, not a modal: a panel in the fixed picker overlay band (None + one cell
    per eligible skill, flat enum order, the current pick highlighted,
    close button top-right) that blocks input only where it physically
    sits - everything around it stays live (placing enemies, undo,
    other panels), and it stays open until a skill is picked or the
    close button is pressed. The view is rebuilt per frame, so nothing
    under it can go stale. One seam: a picker press while a text field
    is focused counts as PROCEEDS in the M2 arbitration (the picker
    floats outside the inspector rect) - the field commits and the pick
    fires in the same click.
  - entity layers: LANDED - the shared Layers section (see the
    decoration bullet below for the row/picker model; entity layers have
    NO dims constraint - the fixed 512×640 frame - and no authored color
    source, so a new layer starts at color 0).
- **Inspector fields (decoration types - LANDED):** the Identity section
  (shared section id with the enemy content - collapse state persists
  across kinds) holds the Sprite row (the centered picker - see below)
  and the Color row (a swatch row over the WORLD gradient - decorations
  index into it, matching the in-game tinting; commits via
  `editor_set_decoration_color_index`). NO name row - a decoration's
  name IS its sprite path (the palette label tracks the sprite). The
  Footprint section's row is a `<N> tiles` button that opens the
  FOOTPRINT EDITOR (below).
- **Inspector fields (item types - LANDED):** one collapsible "Item"
  section (`EditorInspectorSectionId.item`, the shared strip/expansion
  machinery). The TYPE control is TWO pick rows (3 units: a "Type" label
  line + the weapon row + the gear row) - the six weapon types on top,
  the five non-weapon kinds (amulet/coat/gloves/pants/boots) below; SKILL
  TOMES are EXCLUDED (not authorable - the level-file Items section has
  no tome kind, the coupling contract). RESET-EVERYTHING semantics on
  any pick that differs (author decision): the item is replaced by a
  `"New <Kind>"` default (weapons: `"New <WeaponType>"`) with zeroed
  stats - NO retype-keeps-identity case (unlike the entity weapon
  slots); an identical pick never fires. Then the Name field + one
  numeric stat field per stat the kind carries (`itemStatSet`, clamped
  to `itemStatMax` - the parser's own bounds, single-sourced), via the
  shared text-field machinery (`TextFieldId.item_def_name` /
  `.item_def_stat`, target `TextEditTarget.item_type` - the index rides
  the ref so a mid-edit tool switch can't retarget the commit). Event
  routing: `editor_set_item_def` carries the item FLATTENED to top level
  (kind + weapon_type + name + the seven stat fields - a nested `Item`
  payload's name string can't round-trip the session log once it
  contains a space; the `editor_set_decoration_def` precedent) and the
  name commits ride `editor_set_item_name`; both take thin player
  wrappers + validation arms (screen + editor + type-id range). The
  handler clamps stats to the same bounds (the editor never holds a
  state its own load path would clamp away) and keeps the palette label
  (`id`) synced to `itemDisplayName` (the decoration id-tracks-the-sprite
  rule). Item content tints with the PLAYER gradient (matching the Items
  palette group).
- **The footprint editor (LANDED):** a centered picker panel (the
  `.decoration_footprint` picker kind) showing the type's sprite
  FULL-SIZE (1:1 - 256 screen px per sprite-grid tile; custom stems
  included - their ids resolve to the mission dir at the texture store)
  with one
  toggleable cell per grid tile. The DRAFT - a bool grid on UiState
  (`editor_footprint_draft`, a fixed 64-cell capacity = 8×8 tiles;
  larger custom sprites don't open) - seeds from the current footprint
  at open and flips per cell click (direct UiState writes, off the undo
  timeline; the confirm is what records). A continuous WHITE outline
  (the placement preview's region-edge style - 8px bars centered on
  the boundary, seamless corners) marks the draft-selected region.
  Confirm commits `editor_set_decoration_footprint` (row-major grid
  coords) IF the draft differs - unchanged closes without recording;
  an EMPTY draft stays open (a footprint must reserve ≥1 tile, the
  load-time invariant). The handler ADOPTS + PRUNES: an edited
  footprint re-anchors (bottom-most-then-left-most), so the def
  handler's shared prune runs - placements whose shifted world tiles
  cover a level tile or another decoration are deleted, one undo step
  covering both. The picker target carries the TYPE ID it was opened
  on, so a mid-edit tool switch can never silently retarget the draft
  (toggles/confirm address the stored id; the panel renders from it).
- **The Layers sections (enemy + decoration, LANDED; the player loadout
  has NO layers):** the LAST section of both contents. Per layer, two
  rows - "Layer N" (the sprite-stem button, a re-pick opens the layer
  picker for that index, + Delete) and "Layer N color" (a swatch row
  over the content's gradient, committing the WHOLE layer via the set
  event) - then an "Add layer" row (the picker in add mode). The layer
  index rides the click payload (the `editor_layer` variant, null =
  add). Decoration layers carry the load-time invariant - layer
  pixel dims MUST equal the base's (the level parser panics otherwise):
  the picker's Official tab FILTERS to matching dims so mismatched art
  is never offered, a custom pick resolves dims from its PNG at the
  commit site, and a mismatch keeps the picker OPEN with nothing
  recorded (the pick visibly didn't take). The handler + replay
  validation reject mismatched payloads too, so the editor can never
  hold a state its own load path would reject. A NEW layer's color
  adopts a registry prefab's authored layer color when the picked stem
  is one (tree_1's canopy is 2), else 0; a re-pick KEEPS the layer's
  color (the weapon-retype semantics). Layers never affect placement
  validity - no prune.
- **Metadata sidebar (right bar):** mission + active-level metadata -
  the inspector's EXACT UI model: user-toggleable (top-right button at
  the inspector toggle's height, flush to the right screen edge), CLOSED
  on editor open (a reference panel, not the first thing an author
  needs - unlike the inspector); a per-frame entry list over the shared collapsible-section
  state (both sections COLLAPSED by default, the shared
  `EditorInspectorSectionId` keying + toggle action), view-relative
  windowed emission (only fully-visible rows) + scrollbar + wheel
  routing when the content overflows. Mission section: the mission
  name. Current-level section: the level name + the three gradient rows
  (World colors / Enemy colors / Player colors - label line above with
  the role's EFFECTIVE gradient index flush right (`loaders.effectiveGradientIndex` -
  the override while manual, the derived index while auto, null = no level
  = no number), AUTO toggle + full-gradient swatch on the control line
  below - see "Level
  theme" below). The AUTO toggle works BOTH WAYS: while manual it
  reverts to auto-derivation (the null override); while auto it flips to
  manual by FREEZING the currently-derived index as the explicit pick
  (visually identical - only the outline moves). The outline marks the
  row's mode: the AUTO button while deriving, the SWATCH while an
  explicit pick is in force (the world row's swatch always - its index
  is always picked).
- **Primary actions (top-right): LANDED.** Test + Validate icon buttons
  (the options/undo visual class - `emitIconButton`, `slot_size` square,
  flush at the top-right corner; placeholder sprite ids `ui/icon_playtest`
  / `ui/icon_validate` until art lands). Test = `.test_editor_level` →
  `player_start_playtest` → `start_playtest` on the active level
  (single-level); Validate = `.validate_editor_mission` →
  `player_start_validation` → `start_validation` (full playthrough from
  level 1). Both transition to
  `.level` screen with editor dormant; `end_playtest`/`end_validation`
  return to `.editor`. The bottom bar during playtest/validate is the
  in-game bottom bar (the screen transition handles it; `view()` branches
  on screen). Upload/Publish UI is DEFERRED (lands with online services).

**Centered sprite picker (enemy + decoration, base + layer modes
LANDED).** Picking a base sprite or a layer sprite for an enemy or
decoration tool opens the centered picker (the skill picker's framework,
second consumer - dropdown semantics, blocks only where it sits, stays
open until a pick or close) with TWO TABS top-left and close top-right.
The picker KIND follows the open site: base-sprite rows route by the
inspector target (`.entity_sprite` / `.decoration_sprite`), the Layers
sections' buttons open the layer modes (`.entity_layer` /
`.decoration_layer` carrying the layer index, null = add-new - the skill
picker's slot pattern; see the Layers bullet above for the layer rules:
per-mode Official-tab lists, the decoration dims filter, tinting, and
highlight targets).
- **Mission** - the `.png`s in the mission directory (a flat scan,
  `FileSource.listPersistentPngFiles`; re-scanned at every OPEN from
  the idle-input site - interactive IO never in `view()`/handlers; the
  list is cached on `SessionState.editor_mission_sprites`, the
  `save_files` ownership pattern). A picked `boss.png` in mission
  `artists_den` stores the stem **`custom/artists_den/boss`** -
  namespaced (no collision with official stems) + self-describing in
  the level file. The namespaced id is MINTED AT SCAN TIME
  (`MissionSprite.stored_id`, backing_allocator, freed with the list):
  the pick payload (the `clicked_payload` union's `editor_sprite`
  variant) and the commit id REFERENCE the session-owned bytes - a
  same-frame borrow of
  session-lifetime memory, safe indefinitely (the per-frame view mint
  it replaced allocated `custom/...` into the frame arena every frame
  the picker was open, dying at the render reset - the lifetime hazard
  the observability stash exposed; the picker test pins pointer
  identity: the button's payload IS the scan's string). Resolution
  rule: a stem starting `custom/<mission>/`
  → `{mission_path}/<name>.png` (the mission being played/edited);
  anything else → `entities/{stem}.png` embedded. Mission-local cells
  render the art UNTINTED - custom art keeps its own colors (the
  `keep_original_colors` semantics; see the coloring section) - at the
  entity-frame convention (512×640); decoration kinds aspect-fit at
  the SCAN's IHDR dims (the IHDR read lives on the scan entry).
- **Official** - the shipped `assets/entities/*.png` (comptime from
  the sprite-metadata table), the player body EXCLUDED. Cells draw the
  sprite aspect-fit at the 512×640 entity-frame convention, tinted with
  the enemy gradient at the type's color_index; the current sprite is
  highlighted.
Cells are 256×256, 4 columns, no scrolling (overflow is a follow-up if
real content needs it). The tab state is UiState (a view affordance,
reset to Mission on every open - custom assets take priority). Picking
commits through the existing `player_set_editor_entity_sprite` event
(on the undo timeline + replay-validated); same-value picks close
without recording.

**Decoration picks (LANDED) - the whole-definition commit.** A
decoration pick commits ONE `editor_set_decoration_def` event (the
`editor_set_item_def` precedent - the payload carries sprite, footprint,
pixel dims, color_index, layers, FLATTENED to top level because the
session-log reader doesn't regroup nested non-u8 slices):
- **Official tab = the decoration REGISTRY** (`data/decorations.txt`
  prefabs, session-resident on `SessionState.editor_decoration_registry`,
  loaded at open_editor - gated `!replaying`, the `editor_mission_sprites`
  pattern; a registry failure degrades to empty + popup, the editor
  stays usable). A pick ADOPTS THE WHOLE PREFAB - sprite, authored
  footprint, pixel dims, color_index, layers ("loading a prefab"); the
  palette label (`id`) always tracks the sprite (a decoration's name IS
  its sprite path). Cells render the prefab's AUTHORED composition -
  the shipped `decorations/{stem}` art aspect-fit at the prefab's own
  pixel dims, base tinted with the world gradient at the prefab's own
  color_index, its layers over the base at their own indices (one
  shared fitted rect) - previewing exactly what the pick adopts.
- **Mission tab** - same scan + namespacing as entities. A custom pick
  stores the namespaced stem, resolves pixel dims from the PNG bytes at
  the commit site (`loaders.resolveMissionSpriteDimensions` - a
  vanished/corrupt file commits nothing), and derives a DEFAULT
  single-tile footprint at the sprite grid's BOTTOM-LEFT corner (the
  authored footprint editor is a later slice). Custom picks keep the
  type's current color_index + layers (nothing authored to adopt).
- **Placement prune (the def handler):** a footprint change can
  invalidate the type's existing placements - the handler deletes any
  placement whose translated new footprint covers a level tile or
  ANOTHER decoration's footprint (the `editor_place_decoration`
  invariant; entity/item placements always sit ON level tiles, so the
  tile check subsumes them). The things under the new footprint are
  never touched - the decoration itself is deleted. Runs across every
  level (the palette is mission-shared), one undo step covering retype +
  prune; the selection is reconciled for the active level's removals.
  The same helper serves the future `editor_set_decoration_footprint`
  handler.
- Load-side dims resolution for `custom/<mission>/` decoration stems is
  WIRED: `resolveDecorationSpriteDimensions` takes the mission path from
  `loadLevel` and reads `{mission_path}/{file-stem}.png` - the two-channel
  rule (custom = mission-bundled, everything else = shipped table; no
  assets/ fallback - see the Sprite id convention below). Entity custom
  stems don't need it (entities carry no pixel_dims).
Ground items always render as the shared ground-bag sprite - there is
no sprite to pick for them. The sprite picker + the footprint editor
(see the Inspector fields above) + the THEME PICKER (the metadata
sidebar's gradient rows - every gradient as a fixed-size strip of
6 × 128px swatch blocks with its 0-based gradient index in a left
number column (matching `gradient_index` in color_themes.txt + the
level's stored keys), one pick per row, the current index framed in
lightest; a pick while an enemy/player role is on AUTO flips it to
manual in the same commit, and an auto-role picker highlights its
DERIVED index; the list WINDOWS to the overlay and scrolls - the wheel
scrolls one row per notch while the picker owns the screen, a scrollbar
(the error popup's track + thumb convention) shows the window's
position, and opening scrolls the level's CURRENT gradient into view)
are the editor's centered panels; everything else stays
inline in the inspector / metadata sidebar.

**The picker OVERLAY (settled):** every centered picker renders in ONE
FIXED rect - `ui.editorPickerOverlayRect`, the band between the two
sidebars (full sidebar-panel height, a `ui_gap` in from each sidebar
panel's edge; 1760×1328 at the current reference size), mirroring the
gameplay scenes' middle-panel band. CONSTANT regardless of the
sidebars' open state, and independent of the picker's content: the
CONTENTS are fixed-size (256px cells, fixed strips - 6-column grids,
the theme picker's fixed strips) laid out centered inside it, so the
overlay never resizes when content grows (more gradients in the wheel,
more sprites). The footprint editor is the one scaler: its grid keeps
1:1 (256 screen px per sprite-grid tile) for whatever fits and SCALES
DOWN (never up) for oversized custom art; the Confirm button is pinned
bottom-center.

**Level theme (gradient picking).** A level's theme is composed from the
authoritative gradient list in `color_themes.txt` - the full color wheel
(24 gradients, one per 15° spoke, INDEX 0 at the wheel's top increasing
CLOCKWISE - machine-extracted from the artist's wheel asset; gradient i =
the spoke at CCW angle 90° − 15°·i). The level stores:
- **world gradient index** - picked from the list (the role
  `color_wheel_index` plays today).
- **enemy / player gradient overrides** - optional indices; when unset
  (the default) the gradient is DERIVED from the world index, equally
  spaced across the wheel for role clarity - the same rule as
  `activeThemeFor`: enemy = world + N/3, player = world + 2·N/3 (N =
  gradients in the theme). Disabling the auto-derivation (per role) and
  picking a specific gradient is the override.

This index-based model SUPERSEDED `CustomColorTheme` (raw 18-color granular
authoring): per-color control is deliberately out of scope - authors pick
from the handpicked wheel. The scaffolding is REMOVED (the type, the
`custom_theme` fields, and `editor_set_level_custom_theme`); Level +
EditorLevel carry `enemy_gradient_index` / `player_gradient_index: ?u32`
(null = auto-derive), serialized as level-file Metadata keys
`enemy_gradient_index` / `player_gradient_index` (absent = auto). Hubs keep
wheel-only derivation (no override fields - hubs aren't editor-authored).
`deriveActiveColorTheme` takes the two optional overrides; `activeThemeFor`
threads them from the live level / the editor's active tab, so the editor
viewport previews the active level's full theme live.

**Ramp spacing rule.** Within every gradient, any two colors the renderer
places adjacent - the ramp steps (0-1 through 4-5) plus the checkerboard
pair 1-3 - must be at least ΔE 6 apart (CIE76 perceptual distance in Lab
space; calibration on the shipped wheel: seams that read broken sit at
ΔE 5.4-5.6, seams that read fine start ~6.8), and the structural seams
(1-2 tiles-vs-background, 1-3 checkerboard, 2-3) keep a WCAG contrast
ratio of at least 1.06 (the same-luminance catch). Enforcement is the
REPORT, not a gate: `scripts/gradient_report.sh` regenerates
`gradient_report.md` (the sound_report pattern - reads
`data/color_themes.txt` through the game's own parser + loader, ranks every
gradient, flags violations, and computes slide repairs: the violating
step's darker color slides along its own ramp toward its darker neighbor
until it clears the floor plus 0.5 headroom - the repair for the
tiles-vs-background class moves only the background color). Everything
else about a ramp's shape (the artist's character) is free.

**Editor viewport rendering (drawable projection).** The editor playfield
never builds a concrete `Level`; `view()` gains an editor-mode branch that
projects the `EditorLevel` structure into the same drawable kinds the
in-game view builds. Placements store their location + a pointer to their
tool reference (tool = palette entry), and the projection resolves each
placement through its palette type to sprites + gradients: tiles,
decoration pieces (footprint split + layers), entity sprite stacks,
ground items (bag sprite), and the `!`/`=` markers all render via the
existing drawable builders. The same placement-through-reference
structure is what save reads to generate the mission files.

**Active-tool model (left clicks fully modal; right-click is the tool-
independent delete).** The active tool is always exactly one
of: {selection, tile-paint, enemy-type-X, decoration-type-X,
ground-item-type-X}. The tool pointer lives on the Editor
(`Editor.active_tool`, GameState) and is set only via the
`player_set_editor_tool` → `editor_set_tool` event pair - tool switches
ride the undo timeline, and any event whose effect depends on the active
tool (the click orchestrators) can read it from reconstructable state.
Selecting a palette slot sets the active tool to that
type and the inspector shows that type's fields. A viewport LEFT click's
effect is determined by the active tool. A RIGHT click is the same
delete regardless of tool (`player_delete_editor_at`): one clean click
deletes ONE thing at the pressed tile - priority: enemy / ground-item
occupant, then covering decoration(s), then the bare tile; the '!' / '='
and empty ground are no-ops. The pressed tile is recorded at press; a
right-drag stays the camera pan (movement-threshold disambiguation, the
`PendingRightClick` gesture state shared with the level-screen inspect).
Progressive delete: clicking an occupied tile removes the occupant first,
the tile goes on the next click.

**No-op clicks never fire.** Each tool's click effect is computed by a pure
planner (`planEditor*Actions` in `src/editor/planning.zig` - one per tool, plus
`planEditorDeleteActions` for the right-click) from the live editor state:
the handler pushes the plan, and the input layer fires the player action
only when the plan is nonempty. A click that would change nothing (paint
on an existing tile, place on the '!' / '=', a same-type retype with
nothing to clear, delete on empty ground) therefore never reaches the
event log - no undo step, no replay step. The planners are the single
source of truth for both sides (no duplicated no-op conditions to drift)
and directly unit-testable; the handlers keep the empty-plan return as the
defensive path for crafted or pre-change session logs (they replay
gracefully - a redundant event in a log is harmless, it just plans empty).
- **Selection tool (click semantics LANDED):** a click's GROUP is
  everything that acts as one unit: the tile INCLUDING the entity / ground
  item standing on it, a covering decoration (the first, exactly what the
  hover preview outlines), or the '!' / '=' singletons - selectable since
  selection is the only way they'll ever be moved. A PLAIN click
  (no Shift) REPLACES the selection with the clicked group
  (`player_replace_editor_selection` - clear everything, then select the
  group); clicking EMPTY GROUND clears the selection (the clicky
  deselect-all); a click that would change nothing (the selection already
  IS the group) never fires. A SHIFT+CLICK (no drag) TOGGLES the group
  (`player_toggle_editor_selection`): anything from the group already
  selected → every present entry is removed (shift+clicking a selected
  tile deselects the tile AND its occupant); nothing selected → the whole
  group is added; empty ground plans nothing. The selection lives on the Editor (`Editor.selection`,
  GameState - ON the undo timeline) and is mutated only via the granular
  `editor_select` / `editor_deselect` events (one per entry; a group click
  pushes the group's events together, sharing the click's idle point, so
  one undo step reverts the whole click - and a future marquee /
  shift-click batch is one undoable step of many additions). Per-click
  undo granularity is ACCEPTED by design: undoing a misclicked selection
  is a feature, and marquee bounds the click count. It renders as outlines
  in the theme's LIGHTEST color (the same as every other world outline)
  around every selected region; changing to a different tool or level tab
  clears it (both clears ride their events). DELETES keep the selection
  consistent WITHIN the same event: the placement-removal arms prune the
  deleted entry and remap the indices above it (an index shift would
  otherwise leave surviving entries pointing at the wrong placements),
  and a tile erased by any flow (right-click, decoration placement) leaves
  the selection with it - so undo/redo restores an edit and its selection
  bookkeeping atomically. This is also the replay-safety foundation for
  the selection OPERATIONS (group move): a selection-dependent handler
  reads reconstructable state, so the recorded log reproduces its effect.
  The shift+drag MARQUEE is landed on the same events: a press with Shift
  held records the press tile (`UiState.editor_marquee`, off the timeline -
  a view affordance like the inventory salvage region); the drag
  threshold promotes it (rectangle renders, the end corner tracks the
  pointer live, keeping the last valid corner over blocking UI); release
  with Shift STILL held adds everything inside the inclusive rectangle via
  `player_select_editor_region` (skipping already-selected entries - an
  add, never a remove; all the adds share the click's idle point, one
  undo step); Shift released mid-drag cancels. Membership: tiles /
  entity / item placements by position; a decoration when ANY footprint
  tile is inside (matching the click hit-testing - if you can click it,
  you can marquee it); the '!' / '=' by their tile. An UNPROMOTED release
  (no drag) IS the shift+click TOGGLE path - the unpromoted shift
  release fires the toggle at the press tile (the select arm defers to
  the gesture while Shift is held; a plain click there would REPLACE). Mirrors the inventory salvage-region gesture.
  The Delete key deletes the selection (`player_delete_editor_selection`
  → `planEditorSelectionDeleteActions`): everything selected goes EXCEPT
  the '!' / '=' entries and the tiles under them (a marker needs its
  ground); a selected tile takes its occupant with it (an occupant can't
  stand on nothing - swept even when unselected); each placement kind's
  deletes process high-before-low (index stability), the tile erases
  process last (position-keyed); one undo step reverts the whole
  deletion. No payload - the handler reads `editor.selection` from
  reconstructable state. Ctrl+D clears the whole selection
  (`player_clear_editor_selection` → the single `editor_clear_selection`
  event - one operation, not a per-entry fan-out; gated on a nonempty
  selection so an empty one never records). Ctrl+A adds EVERY selectable
  thing in the active level (`player_select_editor_all` → the marquee's
  granular-add planner with no region bound - tiles, placements, the '!' /
  '='; skips already-selected entries, so an all-selected level never
  fires; one undo step reverts the whole batch). Ctrl+A is TOOL-AGNOSTIC:
  when another tool is active the action also switches to select - the
  selection can only live there (the selection ⇔ select-tool invariant),
  and the follow-ups (move / delete / refine) are select-tool verbs
  anyway; the switch rides the action's idle point (one undo restores the
  previous tool + the empty selection) and sits LAST in the push so the
  LIFO drain processes it FIRST (the editor_select events run with the
  select tool active). The selection MOVE is landed:
  a plain left press on a selected thing (tile / entity / item, a selected
  decoration's footprint, or a selected marker -
  `editorSelectionContainsPosition`) OR on an unselected-but-selectable
  thing (a nonempty click group - `editorClickGroupNonempty`; empty ground
  never claims, so the click-to-deselect stays the plain release path)
  claims a drag; the threshold promotes it (the view translates the
  OUTLINES by the live delta - the selection for a selected-at-press
  claim, the grabbed click group for an unselected one (`selected_at_press`
  on the drag struct records which; the old selection must NOT slide
  around - it is still the real selection) - the world stays put); a
  selected-at-press release with a nonzero delta fires
  `player_move_editor_selection { delta }`, a zero delta fires nothing,
  and an unpromoted release acts as a plain click (the REPLACE - the
  select arm defers to the gesture; usually a no-op, since the pressed
  thing is selected). An UNSELECTED-claim release - drag-to-select-and-
  move, one gesture instead of click-then-drag - fires the replace +
  move PAIR, pushed in drain-correct order: the move first, the replace
  ON TOP, so the LIFO drain runs the replace's whole sub-batch (select
  the grabbed group) before the move orchestrator plans its clear phase
  + chained commit against the REPLACED selection - the ordering is
  guaranteed by push order, not by drain timing, so a fast flick can't
  interleave them; both actions push in the same frame, drain together,
  and share one idle point (recorded when the stack EMPTIES, not per
  action), so a single undo step reverts the whole drag. A zero delta
  drops just the replace (the grab-and-drop-in-place = selected, like a
  click). The commit: the handler backs the selection
  up as concrete things (`EditorSelectionMoveEntry` - kind + type_id +
  target), pushes the clear plan
  (`planEditorSelectionMoveDeleteActions` - like the Delete key but an
  UNSELECTED occupant PINS its tile: the ground stays under it and the
  moved tile lands at the target instead; markers + their tiles
  protected) and then a CHAINED `editor_commit_selection_move` worklist -
  each link plans ONE entry against the live post-clear state via the
  placement planners (the current placement rules; chained because
  up-front planning breaks when entries' targets share a covering
  decoration or interact via index shifts), and the exhausted link CLEARS
  the selection (a move deselects - nothing is reselected). A moved
  marker sets its coordinate via `editor_set_player_start` /
  `editor_set_level_end`, takes its OLD ground with it (the clear phase
  erases the tile it stood on - nothing hosts it there anymore; the
  Delete key's marker-tile protection applies only when the marker isn't
  moving), and a tile is ensured under the new position; a
  thing whose target overlaps a marker plans empty and is deleted fully.
  One undo step reverts the whole move. The selection operations are
  complete.
  Placing does NOT happen in selection mode. The tool-switch clear rides
  the `editor_set_tool` event (invariant: selection nonempty ⇔ active tool
  is select), so one undo step reverts a tool switch together with its
  selection clear.
- **Tile-paint tool:** one click = one tile (`player_paint_editor_tile`,
  LANDED). A click on empty space paints a floor tile; a click where a
  tile already exists is a no-op (entities / items / the `!` / `=` sit ON
  tiles, so they never block a paint); a click covered by a decoration
  footprint REPLACES the decoration - every covering placement is deleted,
  then the tile is placed (the click's delete + place sub-events share one
  idle point, so one undo reverts the whole click). EVERY tool resolves
  the tile cursor and draws its outline at the
  cursor position unconditionally (over empty space too - the affordance
  that a click can act there; arrow keys nudge it without the level/hub
  clamp-to-real-tile); the decoration tool renders a CONTINUOUS outline
  around the whole footprint region instead (one `region_edge` overlay
  per boundary edge - any footprint shape reads as one closed outline),
  anchored so the decoration's ANCHOR tile sits at the cursor, and the
  select tool previews what a click would select (a covering
  decoration's footprint region, else the single tile).
  Drag-painting is LANDED: a plain left press paints the tile directly
  under the cursor immediately (a clean click is indistinguishable from
  the old click path - same planner, same no-op gate), and while the
  button is held each tile the pointer ENTERS that the drag hasn't
  visited yet paints the same way (`handleEditorTileDrag` in
  input_gestures.zig - the marquee/move-drag gesture pattern; the visited
  set lives on SessionState, reset at press, so wiggling back over
  painted ground never re-fires). Paints fire only at an EMPTY event
  stack - a plan computed while earlier events sit unprocessed could
  reference placement indices those events are about to shift (the
  decoration-delete hazard) - and pause while the pointer is over
  blocking UI (the marquee's last-valid-corner rule). Undo granularity
  is PER TILE by design. Does not modify the selection set.
- **Placement tools (entity/decoration/item type):** click places one
  instance of that type at the cursor position. The ENEMY tool is landed
  (`player_place_editor_entity` - the decoration/item tools mirror it
  later): the click's effect is computed from state as occupant
  replacement - player start / level end → no-op (never overwritten);
  covering decoration footprints → deleted; missing tile → placed (the
  enemy stands ON a tile); co-located ground item → deleted; existing
  enemy → RETYPED in place (`editor_set_entity_placement_type` - identity
  + position stay stable, preferred over delete + re-place; same type
  already there → nothing to do); empty tile → `editor_place_entity`.
  **One thing per placed tile is an invariant** - `editor_place_entity`
  and `editor_place_item` panic on an occupied tile (the orchestrator
  clears occupants first); future move/drag handlers must preserve it.
  The enemy + ground-item tools share the single-tile cursor (see the
  tile-paint tool above). Placing does NOT select the placed instance -
  you switch to the selection tool to select. (Auto-select-after-place is
  deliberately NOT the model; keeps tool responsibilities disjoint.)
- **Decoration tool (landed, `player_place_editor_decoration`):** the
  INVERSE occupant replacement - a decoration's footprint tiles are
  TILE-FREE, so covered tiles are ERASED rather than placed. The '!' / '='
  under ANY footprint tile → no-op; tiles under footprint tiles → erased
  along with the entities / ground items standing on them; other
  decorations whose footprints overlap ANY footprint tile → deleted; an
  EXACT DUPLICATE (same type at the same anchor → identical footprint)
  already satisfies the placement - the plan skips the place and the
  duplicate's own delete, so no duplicate ever stacks (the other overlap
  deletes still fire);
  then the placement lands. `editor_place_decoration` enforces footprint
  exclusivity (panic if any covered world tile carries a level tile, an
  entity/item placement, or another decoration's footprint at place time
  - the click orchestrator clears occupants first). The preview is the
  footprint region outline (see the tile-paint tool above).
- **Ground-item tool (landed, `player_place_editor_item`):** the enemy
  tool's occupant replacement with the two placement kinds' roles
  swapped - an existing ground item is RETYPED in place
  (`editor_set_item_placement_type`), while an enemy on the tile is
  DELETED (an item can't coexist with it). Otherwise identical: '!' / '='
  → no-op; covering decoration → deleted; missing tile → placed;
  `editor_place_item` carries the same one-thing-per-tile guard. Single-
  tile cursor outline.

**Selection model (`Selectable` union).** The viewport can contain
heterogeneous selectable things; multi-select is a REQUIRED feature
(landed: the shift+drag marquee - see the selection tool above). A `Selectable` union covers all kinds:

```zig
Selectable = union(enum) {
    tile: Vector2,                   // a floor tile (paint/erase target)
    entity_placement: usize,         // index into editor.levels[i].entity_placements
    decoration_placement: usize,     // index into decoration_placements
    ground_item_placement: usize,    // index into item_placements (new editor placement type)
    player_start: void,              // the '!' - singleton, movable not deletable
    level_end: void,                 // the '=' - singleton, movable not deletable
};
```

The selection set is `[]Selectable` - LANDED as `Editor.selection`
(types.zig `Selectable`, placement indices are u32) on the undo timeline,
mutated only via the `editor_select` / `editor_deselect` events pushed by
the `player_toggle_editor_selection` click orchestrator (see the
selection tool above for the granularity + undo semantics; the delete
arms prune deleted entries and remap shifted indices within the same
event, so the set stays consistent across edits AND across undo/redo).

**Marker invariant (`player_start != level_end`).** The layout format
  gives '!' and '=' one cell each, so both markers on one tile has no file
  representation - the move framework makes it unrepresentable in-game
  too: `planning.editorSelectionMoveVetoed` (pure, final-positions - a
  move of BOTH markers together preserves their offset and never vetoes;
  a pre-existing overlap, constructible only in crafted states, is only
  ever resolved by moving one marker alone, never created) gates the drag
  at the input layer, and `planEditorSelectionMoveActions` (the move
  orchestrator's whole plan - translated entries as the commit-chain
  worklist + the clear phase) returns empty when vetoed. The commit chain's
  marker arm is the defensive third layer for crafted worklists - a marker
  entry targeting the STAYING other marker's cell plans empty (a LATER
  entry may still move the other away - a crossing is not an overlap).

The click resolution (see the
selection tool above) is the landed hit-testing: '!' / '=' singletons,
first covering decoration, else tile + occupants; the render-order
priority below is the future selection-op refinement. **Inspector tool-type
inference (LANDED, player-as-fallback):** the inspector's target is
resolved by `editorInspectorTarget` (ui/editor_inspector.zig) - a non-optional
`EditorInspectorTarget = { entity_type | decoration_type | item_type |
player }` where
the PLAYER is the FALLBACK (the '!' spawn's loadout): the active enemy,
decoration, or item tool (valid index) wins; the tile tool, an empty
selection, and every ambiguous resolution
land on the player. While the SELECT tool is active the selection is
scanned: tiles / the '=' contribute NOTHING (legitimately uninspectable -
mixing them with enemies still shows the enemy); the '!' contributes a
`.player` REFERENCE (so the spawn alone - or mixed with anything -
resolves to the player, never to an enemy selected alongside it); entity,
decoration, and ground-item placements contribute their type, resolved
against the
ACTIVE level (an out-of-range placement index or a stale palette type id
is an unresolvable bug-state reference that forces the fallback -
defensive only, the delete arms keep both valid). Exactly one distinct reference → that type's fields (editing
the type updates every placement of it - selecting several tiles whose
entities are all the same type shows that entity tool's fields); two or
more distinct (two entity types, an entity plus a decoration, or either
plus the player start) → the player. The input-side commit sites map
the target to `EntityEditTarget` (player → `player_def`; decoration /
item → null, the entity controls don't render for their content) through
one helper, so display and commits agree by construction. Selecting
`player_start` shows the player loadout fields (`player_def`, reached
by clicking the `!`, NOT by a palette entry - the player isn't a placed
type, it's a singleton spawn). The player content (LANDED): a "Player" header + a
READ-ONLY name line + an Import button + the shared Weapons / Gear /
utility-skill-row sections + a read-only inventory item count - NO base
stats / sprite / color sections (strictly enemy-authorable; the player
template keeps its `player.txt` stats). The Import (`player_import_editor_player`
→ `editor_import_player`, handled inline in processEvent - the default
read needs the reconstruction cache) copies the session's PlayerData
loadout - the exact `build_player_from_data` field set: name, gear,
inventory, utility skills (PlayerData carries no base stats) - as a DEEP
copy; with no session data (an empty `player_name`) it parses
`data/new_player.txt` instead (a read source, not a session load).
`player_start` and `level_end` are NEVER deletable, only movable (updating
the level's `player_start`/`level_end` via an editor event). Multi-select
that includes them is allowed for move/bounds but they have no type to edit.

**Ground items (the Items palette).** Levels already support loose floor
items via the `Items` section + layout char code (`GroundItems{position,
items}`). The editor's third palette group (Items) places
single items not tied to an enemy - the level designer's custom loot.
Placements store `(type_id, position)` into an `item_types` palette, same
reference model as enemies/decorations. The palette's item kinds are the
authorable set exactly (weapon/amulet/coat/gloves/pants/boots - skill
tomes are NOT level-authorable, so the palette + its inspector never
offer them; see the Inspector fields bullet above for the item content).

**Viewport hit-testing.** The selection tool needs click → `Selectable`.
Priority follows the render order (topmost-drawn = topmost-selectable):
entities over decorations over ground items over tiles; `player_start`/
`level_end` are selectables at their tile. Derived from the view drawable
list (decorations selectable through their full bbox, not just footprint -
to be confirmed when the editor viewport is wired).

**Implemented:** types (`Editor`/`EditorLevel`/`EntityTypeDef`/
`DecorationTypeDef`/`EditorMode`), the framing events (`open_editor` /
`close_editor` / `start_playtest` / `end_playtest` / `start_validation` /
`end_validation`) + `editor_set_active_level` with full handlers, exit guard in
`end_level`/`end_mission`, `open_editor` action + main-menu "Editor" button
(dev entry, hardcoded to `beginnings`), `parseEntityDefinition` (extracted,
shared by enemy + player loading), `loadPlayerLoadout` + `player.txt` format
(`PlayerLoadout` section), `buildEditorMission` (dedup-on-load),
`instantiateEditorLevel`, round-trip test (open → playtest → end → close,
asserts palette + player_def + instantiated entities). `beginnings` ships a
`player.txt`. The tile-paint slice is landed (see Active-tool model above):
`player_paint_editor_tile` (orchestrator + replay-validation arm + idle-input
consumption), the `editor_set_tile` / `editor_delete_decoration_placement`
handlers, the tile-tool cursor resolution + overlay, and the editor screen
runs handleIdleInput's editor arm (viewport clicks reach the world). Editor
bar restyle: collapsed (or empty) groups sit flush against the bottom of the
screen (expanded groups keep the hovering strip), and every editor `+`
(palette add-new + the add-level cell right of the level tabs) is a square
`ui/panel` cell; BOTH are wired (palette add-new from the shipped
palette defaults, add-level from the `data/default_level.txt` template),
and the level tabs carry their × delete buttons (see the tabs bullet
above). Enemy-tool clicks landed (see Placement tools above):
`player_place_editor_entity` + the `editor_place_entity` /
`editor_delete_item_placement` / `editor_set_entity_placement_type`
handler arms, and `handleIdleInput`'s editor arm is now a tool switch (tile
paint + enemy placement wired). Decoration-tool clicks + the footprint
region-outline preview landed too (`player_place_editor_decoration` +
`editor_place_decoration` / `editor_delete_entity_placement` arms, the
`region_edge` overlay type, `loaders.decorationFootprintWorldTiles` as the
single source of the anchor-translation formula). Ground-item-tool clicks
landed last (`player_place_editor_item` + `editor_place_item` /
`editor_set_item_placement_type` arms) - every placement tool now has
left-click input; the tool-independent right-click delete
(`player_delete_editor_at` + the `PendingRightClick` gesture union) landed
after it. The select tool's plain-click selection landed
(`types.Selectable` + white selection outlines + the hover preview), and
both it and the active tool pointer migrated onto the Editor
(`Editor.selection` + `Editor.active_tool`): selecting is undoable
(`player_toggle_editor_selection` → granular `editor_select` /
`editor_deselect`; see Selection model), tool switches and level-tab
switches clear the selection inside their own events, and the delete arms
reconcile it atomically. The shift+drag marquee landed too
(`player_select_editor_region` + `planEditorRegionSelectActions` + the
`handleEditorMarquee` gesture - footprint-intersection membership,
unpromoted shift release is the toggle path; see Selection model), and so
did the selection DELETE (Delete key → `player_delete_editor_selection`
+ `planEditorSelectionDeleteActions`; markers + their tiles protected),
and the selection MOVE (`player_move_editor_selection` + the chained
`editor_commit_selection_move` worklist + the `handleEditorMoveDrag`
gesture - see Selection model), and so did the tile-tool DRAG-PAINT
(`handleEditorTileDrag` - press paints the tile under the cursor, held
paints each newly-visited tile; see Active-tool model). Remaining
viewport input: none.

**Event structs DEFINED, handlers landing per slice.** Every edit-verb event
struct exists in events.zig (`editor_add_level` / `editor_delete_level` /
`editor_set_tile` / `editor_set_level_name` / `editor_set_level_color_wheel`
/ `editor_set_level_enemy_gradient` + `editor_set_level_player_gradient`
(LANDED - the per-role gradient overrides; they superseded + removed
`editor_set_level_custom_theme`, see Level theme below) /
`editor_set_mission_name` (LANDED) /
`editor_set_player_start` / `editor_set_level_end` / `editor_add_entity_type`
/ `editor_add_decoration_type` / `editor_add_item_type` (LANDED - built
from the shipped defaults, data/editor_defaults.txt) /
`editor_delete_type` (LANDED - the palette tool cells' delete buttons;
see the tool-palette bullet) / `editor_place_entity` / `editor_place_decoration` /
`editor_place_item` / `editor_delete_*_placement`
/ `editor_set_entity_*` (the scalar field setters + the ONE unified
`editor_set_entity_gear` equipped-slot commit - flattened item fields,
the whole-definition shape) / `editor_set_decoration_def`
(LANDED - the whole-definition commit; the per-field name/sprite setters
were superseded and removed) / `editor_set_decoration_color_index`
(LANDED) / `editor_set_decoration_footprint` (LANDED - the footprint
  editor's confirm; adopts + prunes via the shared helper) /
`editor_set_item_*` / `editor_add_*_layer` / `editor_remove_*_layer` /
`editor_set_*_layer` (the six layer arms LANDED)).
`handleEditorEvent` implements every landed arm:
`editor_set_tile` both directions, the `editor_delete_*_placement` trio,
the placement trio + the two retype verbs
(`editor_set_entity_placement_type` / `editor_set_item_placement_type`),
the full entity field set (name / sprite / color_index /
displays_weapons / the four base stats / the unified
`editor_set_entity_gear` / `editor_set_entity_utility_skill`),
`editor_set_decoration_def` + `editor_set_decoration_color_index` +
`editor_set_decoration_footprint`, `editor_set_item_def` /
`editor_set_item_name`, the six LAYER arms, the selection set
(`editor_select` / `editor_deselect` / `editor_clear_selection` / the
chained `editor_commit_selection_move`), `editor_delete_type` (the
palette-type orchestrator), `editor_set_tool` /
`editor_toggle_inspector` / `editor_toggle_metadata_sidebar`, and the
settings-sidebar metadata arms. `editor_set_active_level`,
`editor_import_player`, the `editor_add_*_type` trio, and
`editor_add_level` (the template read) are handled
inline in `processEvent` (they need the reconstruction cache);
`editor_delete_level` is in `handleEditorEvent`. Every edit
verb in the union has a handler; an unhooked future verb hits the
switch's fail-fast `else => @panic("editor event handler not
implemented")` arm rather than silently no-op'ing. Placement moves have
no dedicated verb: they compose from the existing delete/place planners
via the chained `editor_commit_selection_move` - the never-pushed
`editor_move_*_placement` trio was removed (stable-index single-move
verbs considered and rejected; history in DONE.md). Remaining
handlers land with their UI slices.

**Pending:** editor UI/input - the layout + active-tool + selection model
above, implemented as a vertical slice (static shell first: tabs + viewport +
bottom bar + inspector + metadata sidebar rendering with real data, no
interaction; then wire input per tool + the edit-verb handlers). The
viewport shell includes the editor drawable projection (see Editor viewport
rendering above). Still-needed event structs: none - the gradient-override
setters landed with the settings-sidebar slice. Remaining: validation result +
replay attachment (deferred with online services), editor autosave
(nice-to-have).

## Testing

Settled test-suite design: what the suite exists to catch, where each kind
of test lives, and the assertion shapes that don't churn. Working rules -
how to RUN tests, the arena blind spots, the no-`expectPanics` workaround,
sweep-script discipline - stay in AGENTS → Build & Test; this section is
the "what a good test looks like" contract. Motivating history: the 128px
top-bar geometry change broke ~15 window-census tests whose assertions
pinned DERIVED facts (element counts, visible-row windows, pixel positions)
while every builder's semantics was unchanged (DONE.md, "Top bar shrunk to
128px").

### The four bug classes

The suite exists to catch exactly four classes of bug. Every assertion
should serve one of them:

1. **Determinism/replay breakage** - a handler that pushes different
   children than the recording, state that reconstructs differently.
   The natural-stack replay verification + the main.zig round-trip
   reconstruction test are the backbone; anything touching event
   ordering or state shaping must keep them exact.
2. **Gameplay semantic errors** - combat math, skill behavior, turn
   flow, movement. Caught by contract tests pinned to the semantics
   the design specifies, not to what the code happens to do.
3. **Format round-trip corruption** - config/save/session-log
   writer↔reader pairs drifting apart. Caught by round-trip tests
   with awkward values.
4. **UI structural emission errors** - a row never emitted, a window
   that skips content, a scrollbar that disagrees with overflow,
   hit-testing that misses what's drawn. Caught by STRUCTURAL
   assertions, not geometric ones.

**Corollary - the deletion criterion:** an assertion that serves none of
these classes is asserting a fact that changes BY DESIGN (derived geometry,
hand-pinned counts, snapshot windows). It breaks on the next intentional
layout/content change while carrying no bug-catching information.
Delete it.

### Tiers - where tests live

- **Pure-function contract tests: inline in the owning file.** No
  scaffolding, sits next to the contract it pins, and sees file-private
  symbols - which also keeps the minimize-`pub` rule honest (no `pub`
  needed for a test).
- **Handler drain tests: `handler_tests_*.zig`, one category per file**
  (gear / combat / ai / turnflow / editor / autosave / devtools), via
  `test_harness.zig` - each test a scripted mini-session: push to a
  precondition, push the event under test, `runToIdle`, assert on
  `current_state`. Contract tests by construction: they run the real
  `processEvent` dispatch, never a helper the handler doesn't use.
  **Per-variant convention:** every new event variant lands with ≥1
  drain test in the tier file it arrives with (no coverage matrix -
  see Rejected below).
- **Skill contract tests: `skill_tests.zig`** - one per skill: cast
  semantics + AI priority/selection, from the design doc's semantics.
- **UI structure tests: inline in the owning ui file**, using the
  assertion patterns below. The `editor_inspector.zig` split (~4,900
  lines, ~1,700 of them tests) is deliberately deferred until the
  census sweep shows how much of that test mass survives deletion.

### Assertion patterns (the anti-churn core)

- **Contract over mechanics.** Assert what the function/handler PROMISES
  (the design-doc semantics), not how it computes. The `aggro_around`
  tests locked in a mover-centric bug by asserting the mechanic instead
  of the contract - tests copied from behavior re-assert bugs.
- **Derive the expectation from the source the code iterates.** Counts
  from the same enum/list the code walks, label lists from the same
  row list the builder lays out (the utility-skill census is the model:
  self-updating, still catches emission bugs). Hand-maintained
  duplicates of machine-derivable facts are drift by definition.
- **Exhaustiveness properties over pinned windows.** The UI census
  shape: iterate ALL scroll offsets (or all clamp/branch cases),
  collect what is ever visible, and assert the structural property -
  every field id reachable somewhere, nothing visible twice, clamps
  hold at the boundaries, scrollbar present iff overflow. Geometry is
  the INPUT to the test, never the expectation: a layout change moves
  the window, the property still holds. Strictly stronger than a
  pinned window at catching emission bugs, and immune to intentional
  geometry churn.
- **Semantic queries over positional ones.** "The `.max_health` field
  is visible" (find by field id / action / text), not "row 3 of the
  scroll-14 window is `Max health`".
- **One assertion KIND per fact.** A label census + per-field string
  checks + pixel positions all pinning the same window is triple churn
  surface for one fact. Pick the strongest kind; drop the rest.
- **Census helpers print found-vs-expected on mismatch.** A census
  break should be a 30-second read, not archaeology.
  `expectInspectorLabels` (ui/editor_inspector.zig) is the pattern;
  hoist a shared helper as files adopt it.
- **Awkward values.** Boundary-invisible bugs hide behind nice values:
  `computeHarvest`'s cleanly-divisible ratios hid multiply/divide
  order, a `warnings: null` round-trip skipped `validateKeys`
  entirely. Use fractional rates, non-null optional payloads, empty
  and max states - the value that makes the arithmetic order MATTER.

### Deletion policy

When a change subsumes a test with a stronger form - an exhaustiveness
property covering a pinned window, a derived census covering a
hand-pinned count - the old test is DELETED, not ported alongside.
Strength is the criterion, not test count: a suite that only grows
accretes churn. The ~15 broken census tests of the 128px incident are
the archetype - each carried near-zero information and still cost a
fix on a semantics-neutral change.

### Rejected: coverage matrix (event variant → has ≥1 test)

- **Comptime assertion: impossible.** "Has a test" isn't comptime-
  observable - test names are strings, and there's no reflection over
  which tests exist.
- **Grep report (script diffing pushed variants in test files against
  the `events.zig` union): lies in both directions.** Tests push via
  helpers (`pushEvents`, `pushPlayerSkillUse`, harness starting
  states), so it under-counts; non-push references over-count. A
  report that's wrong some of the time trains people to ignore it.
- **Blanket smoke test (push every variant, run to idle): dies on the
  fail-fast force-unwraps.** Most variants need legal preconditions,
  so per-variant setup reappears - hand-maintained curation again.

Decision: the per-variant convention (Tiers above) is the mechanism. The
first untested-variant bite was `swap_positions` (rewritten untested). If
a second lands, write the grep report THEN and accept its inaccuracies as
advisory.

## Decorations & Footprint

Decorations are multi-tile sprite props placed in levels/hubs. Each carries a
**footprint** = the set of world tiles it reserves; the sprite may visually
**overhang** tiles outside the footprint (e.g. a tree canopy over non-trunk
tiles). The footprint is part of the level/hub file per decoration entry so
custom sprites can have large footprints the same way official ones do.

**Config format.** A decoration entry group carries the base fields plus an
optional `color_index` and zero or more `layer` sub-groups. The footprint is a
list of tile coordinates in the sprite's own tile-grid (top-left of the sprite
bbox = `(0,0)`), one per `footprint` line. Example:
```
Decorations
character_code T
sprite tree_trunk
color_index 4
footprint 1 2
layer
sprite tree_canopy
color_index 2
layer
sprite tree_grass_back
color_index 2
behind true

character_code R
sprite ruin_1
color_index 0
footprint 0 0
footprint 1 0
footprint 0 1
```
The footprint list is in sprite-grid coords (NOT anchor-relative):
unambiguous and authorable by marking the solid tiles of the sprite. Blank
lines end an entry (as everywhere). A `layer` line is a DELIMITER: the
following `sprite`/`color_index`/`behind` pairs belong to that layer until
the next `layer` or end of entry. The base's own `sprite`/`color_index` are
top-level keys on the entry (the base owns the footprint). A layer is an
OVERLAY (drawn over the base) unless it carries `behind true` - then it
draws BEFORE the base, showing through its transparent pixels (e.g. the
trees' `grass_back`: grass meant to sit behind the trunk). The writer emits
`behind true` only when set; the picker's ADD commit adopts a registry
prefab's authored draw side for the stem, a re-pick keeps the layer's, and
the color-swatch commit keeps the whole layer (behind included). The
inspector's layer slot row carries a Back/Front toggle (the draw side at a
glance next to the stem) - a flip commits the whole layer through the set
event, the color swatch's commit shape.

**Sprite id convention: bare stems.** All config `sprite` values store the
BARE STEM (e.g. `tree_1`, `skeleton_1`, `player`), not the full asset path.
The code prepends the asset folder (`entities/{s}` for entities,
`decorations/{s}` for decorations, `weapons/{s}` for weapons, `skills/{s}`
for skills). The comptime sprite-metadata table (dims) is keyed by the full
asset-relative path, so the parser's `resolveDecorationSpriteDimensions`
prepends `decorations/` for the shipped-table lookup. Custom stems
(`custom/<mission-dir>/<file-stem>`) are NOT assets/ paths - the dir
component is IDENTITY ONLY, never a lookup into another mission's
folder: **custom art lives in the mission's OWN directory (the
single-dir rule), and nothing ever resolves it elsewhere.** The two
consumers agree because the save enforces the invariant:
- **Load-time dims** read `<mission-path>/<file-stem>.png` (the mission
  being loaded).
- **Rendering** - the texture store has no mission context, so the id
  must be self-describing: `<kind>/custom/<mission-dir>/<file-stem>`
  reads `missions/<mission-dir>/<file-stem>.png` (`assetPathFor` in
  src/raylib/textures.zig; the id's folder prefix is dropped - custom
  ids never map onto `assets/`). The save (see The save/export flow)
  normalizes every stem's namespace to the save target AND copies the
  referenced art there, so the embedded dir IS the mission's own dir for
  anything that round-trips a save. Legacy content authored before a
  rename (stems naming an old dir) renders while the old dir exists and
  warns at load until re-saved - the save's migration read + rewrite
  self-heals it.

**Derived, not stored:**
- **bbox** = sprite pixel dimensions / 256 (tiles_w × tiles_h). A footprint
  coordinate outside the bbox → parse error (fail fast).
- **anchor** = bottom-most-then-left-most footprint tile. The decoration's
  placement position (the layout char) is the anchor tile. Non-anchor footprint
tiles are implicit in the layout (space = no tile, so they're automatically
tile-free); the parse-time check catches a `.`/`!`/`=`/enemy char colliding
with a footprint-covered world tile.

**Placement invariant (parse + editor).** A world tile under a decoration's
footprint must NOT also be a level/hub tile - decorations sit on top of tiles
only via non-footprinted overhang. The parser rejects this at load. In the
editor both directions REPLACE rather than block: painting a tile over a
footprint deletes the covering decoration(s) first, and placing a decoration
erases the covered tiles along with anything standing on them (plus any
overlapping decorations) - each click's sub-events share one idle point, so
one undo reverts the whole click (see the tile-paint + decoration tools in
DESIGN → Architecture → Level Editor → Active-tool model). A decoration's
footprint tiles are also exclusive of each other (no footprint stacking):
`editor_place_decoration` panics if any covered world tile carries a level
tile, an entity/item placement, or another decoration's footprint.

**Rendering: split per bbox tile, sort by assigned footprint y.** The sprite
is split into one `DecorationPieceDrawable` per **bbox** tile (9 for the tree:
footprint + 7 overhang). Footprint is NOT used to decide what gets drawn -
overhang tiles still draw - it's a layout-reservation field only. Each piece
draws its back layers (`behind true`) first, then the base, then its overlay
layers in config order - the base's transparent pixels are what let a back
layer show.

Overhang bbox tiles (art but not footprint) are **assigned to a footprint
tile** at load so the piece sorts at that footprint tile's `y`, not its own.
This prevents wide entities from clipping through a decoration: in a layout
like `!T` with `!` at `(1,0)` and a tree footprint at `(1,1)` whose canopy
overhangs `(0,0)`, the left canopy piece sorting at its own `y=0` would draw
behind the player's left arm (same y, lower x first); tying it to the footprint
`y=1` draws it after the player, correctly in front.

**Assignment rule** (computed at load, never config): each overhang bbox tile
is assigned to its nearest footprint tile by **Chebyshev distance**; ties
break by footprint scan order (bottom-most then left-most = the anchor
convention). The piece sorts at the assigned footprint tile's `y`; horizontal
tiebreaking among same-`y` pieces uses the overhang tile's own `x`. Nearest
handles both common cases ("canopy directly above trunk" and "canopy wider
than trunk") uniformly; the tie-break only fires when an overhang tile is
equidistant from
two footprint tiles (e.g. an arch spanning two pillars). Open wiring-time
detail: whether an overhang piece's effective sort `x` is its own `x` or the
assigned footprint's `x` (only differs when an entity shares the footprint's
`y` and sits between them - rare; decide by looking at it in view()). Open
edge case: tall multi-`y` footprints with overhang between pillars (no such
art today; revisit if one ships).

**Color.** Each decoration base and each layer carries a `color_index` into
the current theme's **world gradient** (`world_gradient.colors[0..5]`). Tiles
use indices 1 and 3 (checkerboard); the background uses 2; so decorations
should use 0, 4, 5 for well-designed distinction. Default `color_index` = 0
(omitting the key is legal and yields the lightest world color). The resolved
color is passed as the raylib `DrawTexturePro` tint - that multiply IS the
grayscale×color theming path (same as entities/tiles).

**Multi-sprite layers.** A decoration may have a BASE sprite (owns the
footprint) plus zero or more LAYER sprites, each colored independently and
drawn over the base in declaration order (base first, then layers in file
order). Use case: a tree with a trunk (base) and a canopy (layer) colored
differently. A layer's graphic MUST be the same pixel dimensions as the base
(validated at load - fail fast on mismatch); the per-bbox-tile split and
overhang-to-footprint assignment are identical across base + all layers
(same `source_rectangle` per tile), so a decoration piece at a bbox tile is a
STACK: base chunk + N layer chunks, all at the same screen position and
source rect, different sprite ids and colors. One `DecorationPieceDrawable`
per bbox tile carries the base chunk plus a `layers` slice of overlay chunks;
the renderer draws base then iterates layers. This keeps the ground-drawable
count at one-per-bbox-tile (not N×) and the sort simple.

**Per-char-code color.** `color_index` (and layers) live on the decoration
entry group, so all placements of the same char code share the same coloring.
A level wanting two colorings of one sprite uses two char codes (e.g. `T`
and `t`). Mirrored in the editor: a palette decoration carries its color, and
a differently-colored variant is a separate palette entry.

**`data/decorations.txt`** = registry of official decorations (base sprite +
color_index + footprint coordinate list + optional layer sub-groups, NO
`character_code`/position - those are per-level). Used ONLY as editor-palette
prefabs for "add new decoration." Existing decorations already in the
mission's levels populate the palette at editor launch via the existing
dedup-on-load (same as enemies). Custom decorations carry their footprint
inline in the level file (same format), so official and custom share ONE
parser path; the registry is never read during gameplay/replay, only when the
editor adds a new prefab to the palette. Loaded by
`loaders.loadDecorationRegistry` (returns `[]DecorationTypeDef`).

### Occlusion inset (readability for overhang)

A decoration with large overhang can fully occlude an entity / ground items /
flag pole drawn behind it (the overhang bbox tile sorts at the footprint's y,
so it draws after - and on top of - anything on the tiles it covers). The
fix is a thin INNER outline of the occluded thing, drawn over the
decoration, so the occluded silhouette reads through without the decoration
receding (it stays fully opaque and visually in front - "something continues
behind here," not "the tree faded").

**Inner-outline mask = morphological dual of the outer outline.**
`generateOutlineMask` dilates with a DISK structuring element (offsets with
dx²+dy² ≤ t²), producing the OUTER band (transparent pixels within
Euclidean t of an opaque pixel; opaque stays transparent). The INNER band is
the dual: opaque pixels within t of a transparent pixel; transparent stays
transparent. The disk SE is not separable - a single 2D pass,
O(|band pixels| × |disk|), instead of the square (Chebyshev) SE's O(w·h·2t)
separable path - but the mask is cached per sprite (built once), so the cost
is amortized; the payoff is smoother 45° corners (the square SE's band was
~√2 thicker along diagonals). One shared `generateOutlineMask(image,
thickness, side)` with the opacity test flipped by `side`; the dilation core
(`dilateToMask`) is shared with the composite path. A separate
`composite_inset_cache` (keyed by a stack-composition string) holds the
occlusion-inset masks; one mask per distinct stack, built once. Reuses
`outline_thickness` (8 source px) and pure-black tint
(matching the art's own drawn outline, so the inset's unoccluded portion
merges into the existing rim rather than adding a second).

**Composited silhouette (entity weapons + flag banner).** The occluded
thing's silhouette is a UNION of a stack of sprites, composited BEFORE
dilating - required for the INNER band, because dilation doesn't distribute
over the intersection in the inner dual (a weapon overlapping the body
would otherwise leave a spurious internal edge). Stacks:
- **Entity:** base + body layers + weapons (main + off-hand, the off-hand
  flipped). Gear and effect sprites are EXCLUDED (gear is a separate
  concern; effects are transient, and including them would make the outline
  flicker and balloon the cache). Frame canvas = 512×640 (all entity/weapon
  art shares the frame, `source_rectangle` null, so compositing is a trivial
  OR of alpha into the canvas).
- **Flag:** pole + current banner frame. The banner's `source_rectangle`
  selects the animation frame from the 2048×512 sheet, so the occluded flag
  shows the ANIMATED banner's silhouette, not just the static pole. One
  cached mask per banner frame index (8 frames → 8 entries, ~4 MB).
- **Ground items:** single sprite (1-element stack - the degenerate case).
`generateCompositeOutlineMask` decodes each sprite, ORs its alpha (alpha > 16)
into a frame-sized opaque mask (honoring `flip_horizontal` +
`source_rectangle`), then dilates. `OcclusionInsetDrawable` carries the
`[]const StackSprite` + frame dims; the texture store's `getCompositeInsetTexture`
(src/raylib/textures.zig)
builds the stack key and looks up / fills the cache.

**Draw model (no scissor).** The inset mask is drawn over the occluded
thing's FULL sprite rect, tinted black at alpha 128 (50%), in a post-ground
pass after `drawGroundDrawable`:
- over the decoration (occluded region): 50% black on the decoration's color
  → a dark trace of the entity's inner silhouette edge. The cue.
- over the visible art (unoccluded region): 50% black just inside the
  silhouette → a subtle extra darkening that merges into the art's own black
  outline. Continuous ring: faint on the visible part, clear on the
  decoration.
No clipping is needed because the unoccluded overlap is self-subtle (it
reinforces the existing outline rather than competing with it), and the
decoration stays fully opaque - the inset never makes the tree translucent.

**Occlusion gate.** The inset draws ONLY when actually occluded (otherwise
every entity gets a permanent rim). For each non-decoration ground entry E
(entity / ground items / level-end / mission-start marker), find any
decoration piece D drawn AFTER E (greater in the `groundEntryBefore`
`(sort_y, sort_x)` order) whose screen rect overlaps E's screen rect. If
yes, emit one inset draw for E. O(entries × decoration_pieces) per frame,
small constants - fine at current caps.

**Scope.** Occluded things: entities, ground items, level-end + mission-
start markers. Occluders: decoration pieces only (not tall entities over
short entities - deferred; the test is generalizable). The entity silhouette
includes base + body layers + weapons (composited - see above); gear and
effect sprites are excluded. Ground items are single-sprite, so exact. The
flag silhouette composites the pole + the current animated banner frame, so
the occluded flag shows the animated banner.

**All view-side** → off GameState → replay-safe by construction (same as
the tile cursor / animation clock). `view()` emits an `occlusion_insets:
[]const OcclusionInsetDrawable` list (sprite_id, screen_position, color,
alpha) on ViewState; the backend draws it after the ground pass, before
floating world overlays.

**Known approximation: adjacent-entity overlap.** Insets draw in a single
post-ground pass, so one entity's inset could faintly overpaint a neighbor
whose art overlaps the first entity's silhouette rect. Entities occupy
unique tiles but their 512×640 art overhangs neighbors; rare and subtle. If
it shows, the lever is per-thing "draw inset right after its last occluder"
(track max occluding sort index) instead of one post-pass. Not a first-slice
concern.

## Entity & UI Coloring

Entities and UI are tinted by the active theme's gradients via the raylib
`DrawTexturePro` multiply (same path as decorations/tiles).

**Entities** carry `color_index: u32` + `layers: []const EntityLayer` (same
layer model as decorations: overlay sprites, same fixed 512×640 frame + pivot,
colored independently, drawn after base and before weapons). The GRADIENT is
resolved by TEAM (team 0 → player gradient, team != 0 → enemy gradient);
the INDEX - the player entity (entity index 0) uses
`settings.player_color_index` (overriding its entity field at render time),
every OTHER entity - enemy-authored team-0 helpers included - uses its own
`color_index`. So a helper (team 0, not the player) renders player-gradient
at its authored index, visually siding with the player while staying
distinguishable from the player's settings color. Entity layers resolve into
the same team gradient as their base. The editor inspector resolves the
same rule for its content tinting (a team-0 entity type's controls tint with
the player gradient), and the in-game entity-inspect panel already keyed
its gradient on team 0. `entityDefinitionsEqual` compares
color_index + layers for editor palette dedup. **Weapons** are team-gradient
index 1 (player → player gradient, enemy → enemy gradient) and are suppressed
when the entity's `displays_weapons: bool` is false (e.g. wolves); parsed
from `displays_weapons true|false` in the enemy definition (default true).
**keep_original_colors** (`Entity` / `Decoration` / `DecorationTypeDef`,
config key `keep_original_colors true|false`, default false): render the
base sprite + ALL overlay layers UNTINTED - the art keeps its own colors
(custom mission-bundled art is authored pre-colored; shipped art is
authored grayscale for tinting, hence default-off). ONE flag per type -
not per layer: the pre-colored-or-not decision is asset-level, and mixed
stacks (untinted base under a tinted layer) read as mistakes. WEAPONS
stay team-gradient index 1 and health bars / effect overlays stay themed
(our art, not the asset's). The flag is part of a definition's visual
identity: editor palette dedup compares it, and the level-file writer
emits it only when true. Pick-time defaults follow the art source - an
OFFICIAL pick sets it false, a mission-local pick sets it true (the pick
event carries it - one undo step); the inspector's toggle sits ABOVE the
Color row and is the override either way, and the Color row is HIDDEN
while the flag is on (a tint row under an untinted type is a dead
control). Picker previews: the Mission tab renders custom
art UNTINTED (its natural appearance); the Official tab ignores the flag.
**Health bars** are always-on, drawn above the entity's actual art top (same
opaque-bbox scan as the skill-icon anim - see DESIGN → Animation). The scan
is a full `SpriteBounds { top, bottom, left, right }` (one decode per sprite,
cached in the texture store - src/raylib/textures.zig - as
`sprite_bounds_cache`, threaded through
`RenderContext.sprite_bounds`), so the hit flash can center on the rendered
art's real vertical center (top + bottom) and damage numbers can start at a
corner (top/bottom + left/right). Frame-arena-backed lookup keyed by bare
sprite stem. See DESIGN → Animation.
The bar canvas + outline frame are 155×31 native (cropped to the outline's
opaque bbox and downscaled 0.5x from the 384×128 Unity art, at
`assets/world/entity_health_bar_background.png` + `entity_health_bar_outline.png`).
Three draw passes at the same rect: depleted background (full,
`active_theme.darkest`), fill (cropped to `fill_fraction` from the left, team
gradient index 1), outline frame on top (tinted with the same team gradient
index 1 as the fill). The skill-icon anim sits above the health bar (offset
by the bar height + gap) so the two don't overlap. **Levels only** (not hubs);
the gate is a `show_health_bar` bool threaded through `collectEntityEntries`.

**UI** is tinted by the **player gradient** with FIXED indices (not the
player's chosen index - the UI palette is independent of the player's body
color). Bottom bar: inventory/gear/skills buttons = 4; health globe
background = 5, fill = 1, border = 3; skill slot backgrounds = 3, skill
icons = 1; skip button background = 5, skip icon = 1; turn-step indicators =
3; momentum display = 3; weapon swap = 3. `view()` passes `active_theme` +
`settings.player_color_index` to `buildBottomBar`; the helper resolves colors
and threads them through `emitSkillButton`/`emitIconButton`.

## Memory & Budget

Arenas are NOT fixed size: they grow from a backing allocator
(ArenaAllocator → the session allocator → OS/wasm). Allocation
fails only when the backing fails: OS OOM (native, rare) or wasm
`memory.grow` hitting the module maximum / 4 GiB wasm32 ceiling (the
realistic case). Caps are estimates for now, to be tuned from real
measurements (see TODO.md).

- **Session allocator (entry files):** native uses `DebugAllocator` in
  Debug + ReleaseSafe (double-free detection + canaries - the reason to
  keep safety builds checked) and `c_allocator` in other release configs -
  the same allocator the web build uses (libc is linked via raylib).
  Never `std.heap.page_allocator` for the session allocator. The
  DebugAllocator leak report never fires: the entry point doesn't deinit
  the allocator, and process-lifetime allocations (settings, the
  persistent-dir path) are intentional, so a deinit would only report
  false positives.

- **History residency:** ~26 full GameState deep copies resident (16
  snapshot slots + 8 checkpoints + current + initial). Per-copy size ≈
  entities × ~4.2 KB (~90% is the inlined 96-slot inventory) + tiles × 8 B.
- **Enemy inventories are NOT lazy-init.** Inventory dominates Entity size
  but only matters at huge entity counts, which level caps prevent anyway;
  keep the simple inline array + uniform enemy pickup behavior.
- **Level caps bound worst case:** `max_entities = 256` for now (official
  levels ~16, but the level editor + sharing will let players build massive
  levels); `max_tiles ~10k` as a starting estimate. Worst case ≈ 26 ×
  (max_entities × entity_size + max_tiles × 8) ≈ tens of MB.
- **Generous safety ceiling (~256-512 MB)** so runaway bugs (infinite event
  push, bad deep copy) fail fast at a `@panic` instead of killing the tab.
  Not a tight fit - real non-asset usage is single-digit MB for normal levels.
- **`event_history` grows unbounded** (every event, tens of bytes each) to
  power infinite undo. Accepted: growth is tiny, the feature is worth it,
  extreme sessions fail-fast rather than corrupt.

### Asset memory (from the Unity project audit)

Disk size is NOT memory size. Textures are the dominant consumer (~30× the
PNG folder once decoded), not gamestate: GPU needs raw RGBA = w×h×4. Source
art has ALREADY been downscaled to display resolution (the Unity audit's
lever 1 is done): weapons are 512×640 single-pose (~1.3 MB decoded), the
flag banner is 2048×512 (4 MB, an 8-frame sheet). Current assets: 114 PNGs =
2.3 MB on disk, ~60 MB decoded RGBA (~80 MB w/ mipmaps). Audio shipped as
OGG (DESIGN → Audio): 15 sfx (~220 KB) + a 3.3 MB looping music stream.

Two separate budgets:
- **wasm linear heap** - gamestate / events / decoded SFX / temp; small.
- **GPU/texture memory** - browser-managed on WebGL, large, art-driven, off
  the wasm heap. Streamed music also stays off the heap; fully decoded audio
  lands on it.

Levers, in impact order (1-2 DONE; the rest are future work):
1. **Downscale source sprites to display resolution** - DONE. Weapons at
   512×640, flag at 2048×512, entities 512×640, tiles 256×256. Decoded RGBA
   is ~60 MB, reasonable for web.
2. **Stream music as OGG** (raylib `LoadMusicStreamFromMemory`) - DONE.
   Music streams from the OGG bytes (tiny ring buffer + decoder vs the full
   PCM on the heap); the bytes stay resident for the stream's lifetime (see
   DESIGN → Audio → MUSIC LIFETIME GOTCHA).
3. **SFX:** fully decode to PCM (memory trivial); OGG only helps download.
4. **GPU texture compression** (ASTC/ETC2/BC via KTX2/Basis) only if later
   measurements demand it - lossy, WebGL/raylib support fiddly.

Web download budget: art is ~2.3 MB PNG + ~3.4 MB OGG audio (music dominates;
streamed at runtime but still downloaded).

## UI Framework

- `view()` builds a `ViewState` each render from a per-frame arena (reset every frame in the game loop); everything the ViewState points at lives until the next frame
- UI is a flat `[]const UiElement` (tagged union: nine_slice_panel, slot,
  button, text_label, fill_sprite, image, solid_rect), appended in back-to-
  front draw order - no sorting
- Builders (`buildBottomBar`, etc. in `src/ui/`) take a `bounds: Rectangle` and append into a shared `std.ArrayList(UiElement)`; everything positions relative to `bounds`
- Layout is Rect algebra: `Rectangle` has pure methods (`position/right/bottom/centerX/centerY`, `translate`, `inset`, and 3×3 `place*` anchors like `placeCenter`, `placeBottomCenter`, `placeCenterRight`). Plus `screenRect()`, `rowWidth()`, `Row`, `Grid` helpers in `ui/element.zig`
- Screen-space dimensions (widths/heights/sizes/offsets) are `i32` (rendering, not gameplay). Gameplay quantities (health, counts) stay `u32`
- Buttons carry an `Action` (same enum as keybinds) so clicks feed the one input path; skill buttons map slot 1-8 → `skill_slot_N`. Slots are for inventory/gear items only
- Cooldown = semi-transparent overlay image + centered number TextLabel (not a fill fraction). Health globe = `FillSprite` (two sprites: empty drawn whole, full cropped to fraction)
- **Item stat numbers** (inventory + gear + entity-inspect item icons): the at-a-glance version of the item tooltip's stat rows - `emitItemStatLabels` (ui/emit.zig) appends one number per stat, colored by the equipped comparison (green better / red worse / theme lightest equal; a weapon compares INCLUSIVELY against both hands - green while ≥ each hand and strictly better than at least one, red while ≤ each hand and strictly worse than at least one, lightest when equal to BOTH hands (a pure sidegrade - swapping changes nothing) or strictly between the two hands; an empty equipped slot compares against 0, matching the tooltip). Each panel uses the SAME baseline its tooltips use: the inventory and the enemy inspect use the player's equipped gear; the gear panel and the player inspect have NO baseline (their items ARE the baseline) - plain lightest numbers, no comparison. Single-stat items (weapons: damage, amulets: spell damage) sit bottom-left; armor's health bonus bottom-left + the item-specific stat bottom-right - both bottom-aligned, out of the icons' defining top-left art (weapon silhouettes); an UNLEARNED skill tome wears a green outlined "!" in the bottom-left corner (the at-a-glance version of the tooltip's "Activate to learn" line - a learned tome shows nothing, its only remaining value is salvage; baseline-independent, so it renders even while the comparison is suppressed). The material-count label recipe: `material_count_font_size` + `material_count_inset`, black-outlined, non-blocking so the slot beneath keeps its tooltip + interaction; suppressed on the drag source (rides the item icon).
- `highlighted: bool` on Button/Image = reusable edge highlight (renderer outlines opaque pixels); used by the active turn-step icon, selected panel buttons, etc.
- Standard gameplay button/slot is `slot_size` (256 at 4k reference); `ui_gap` (16) between top-level items
- **Text coloring.** `ui.default_tint` (pure white) is the default `color` on every UI element. For sprites (Button/Slot/Image) it means "no tint" (show original art). For TEXT it's the "unset" sentinel: the text renderer's `drawTextLabel` (src/raylib/text.zig) substitutes the active theme's `lightest` (the artist's offwhite) so uncolored text inherits the theme without builders needing a runtime color. Explicitly colored text (via `ui.colored(...)`) passes a non-`default_tint` color and is unaffected. Damage/heal numbers (`floating_text`) already pass `active_theme.lightest` explicitly at their call sites. The substitution is text-only - sprite tints keep `default_tint` = "no tint."
- **Text measurement seam.** `ui.FontMetrics` (raylib-free value type: `base_size` + `[95]i32` per-ASCII-glyph advances) is the single layout-side authority for text width. The backend extracts it from the loaded `rl.Font` (`RaylibBackend.fontMetrics`, a thin wrapper over src/raylib/text.zig's `TextRenderer.fontMetrics`) and threads it through `RenderContext.font_metrics` into the builders. Its contract: **mirror the renderer's cursor advance exactly.** `measureSpanWidth` reproduces `rl.drawTextEx`'s per-glyph step (`advanceX × font_size/base_size + spacing`, float-accumulated), so laid-out width == drawn width and multi-span emit (`x += measureSpanWidth`) flows like one continuous string. The shared `glyph_spacing_font_divisor` constant is the one source of truth for the spacing both read - any new draw parameter the layout needs to know (letter-spacing, kerning) must be added there, not re-derived in the seam. Vertical: **center on the `font_size` glyph cell, stack on `lineHeight`** - raylib draws a glyph from the top of a `font_size`-tall cell, so centering that cell (not the 1.2× `lineHeight` box) puts the visual mass on the element's center; `lineHeight` is for multi-line y-advance only.

### UI state classification (GameState vs UiState)

UI state splits into four classes, and the class decides where the state
lives - a rule, not per-field judgment. (Settled after the editor inspector
toggle and the in-game middle-panel toggles had drifted into two conventions
- the editor flags moved onto GameState only because handlers needed to
mutate them; the rule generalizes that precedent to all surface state.)

1. **Semantic surface state - what's open.** Lives on GameState
   (`types.UiSurfaceState`): the middle panels + full-screen overlays
   (ordered sets - open order IS display order), the modal overlays (options
   menu, settings, load-save, credits, tips, editor browser), the entity-
   inspect
   target, and the editor's centered picker (on `Editor.picker`, the
   `Editor.inspector_open` convention). ALL of it changes via events
   (`toggle_ui_surface` / `inspect_entity` / `editor_open_picker` /
   `editor_close_picker`, pushed by their `player_*` orchestrators) so it
   rides the undo timeline and replays - which is what lets
   `validatePlayerAction` gate gameplay orchestrators on the surface that
   supplies their trigger (a salvage without the inventory open is an
   illegal log - see Determinism → Replay PLAYER-ACTION LEGALITY) and what
   lets a reconstructed session show the surfaces the player had open.
2. **View affordances within a surface** (settings tab, editor-browser kind
   tabs, mission-browser tab, sprite-picker tab, palette accordion,
   inspector section expansion, the editor inventory's selected slot) -
   `UiState` (SessionState, off the timeline), direct writes in the input
   layer. Gates nothing gameplay-relevant.
3. **Scroll offsets** - `UiState`, direct writes. Unbounded frequency (one
   per wheel notch), semantically empty, never gates an action.
4. **Mid-interaction lifecycles** (drag / pending presses / marquee /
   text + keybind edit buffers / the footprint draft / the active slider) -
   `UiState`, direct writes. The COMMIT is the event; the gesture or buffer
   never needs replay.

**Idle points: surface toggles are ordinary player actions.** A toggle
fired while idle creates its own idle point (one click/key = one undo
step - the same anytime semantics as `swap_weapons`); a toggle fired
mid-drain rides inside the surrounding subtree (the anytime-interjection
pattern - no idle point of its own; undo reverts to the drain's idle
point, discarding the toggle with the partial drain). No special
idle-point machinery - the existing anytime-action recording covers both.

**The screen/world-change reset splits by the same rule.** Class-1 surface
closing is HANDLER work (`transitionScreen` clears surfaces on screen
change; `start_level` / `start_hub` close them when installing a world at
the same screen), so replay reproduces it. Classes 2-4 reset wholesale in
the live loop (`gameLoop` clears `session.ui_state` on screen or
world-generation change) - off the timeline, the live reset is the only
reset they need.

`pending_error` (SessionState) is deliberately NOT a surface - the
recoverable-error popup is environmental, not player action (see Error
Handling). The mission-complete overlay stays payload-carrying GameState
(`last_completed_mission` + `dismiss_mission_complete`); the mission-fail
overlay stays DERIVED (`playerDead`) - both already satisfy the rule's
goal, so they keep their existing shapes.

### Entity inspect

The entity-inspect middle panel (`buildEntityInspectPanel`, opened by right-
-clicking a world tile with an entity - levels only) is a READ-ONLY mirror of
the player's skill bar + active effects + gear panel. It shares the middle-
panel band + `middle_panel_height` with inventory/gear/skills; which entity
it shows is the entity-inspect surface's target on `UiSurfaceState`.
Middle panels are TOP-ANCHORED
in the band: `middle_panel_height` is the inventory grid's exact-fit content
height (derived: header + gaps + rows×slot), not the band height - the strip
between the panels' bottom edge and the bottom bar is the indicator row's
dedicated space (momentum / effects / turn steps sit flush against the
bar, so open panels never cover them).

- **Read-only by construction.** Every slot is an `.image`, never a `.slot`
  or `.button` - so no `SlotRef` (not draggable from/to) and no `Action`
  (not clickable). Tooltips still work (`.image` carries `tooltip`; `tooltipAt`
  hit-tests it). This is the seam: the inspect panel reuses the bottom bar /
  gear panel's visual recipe but swaps the interactive element type for an
  inert one with the same sprite + tint.
- **Team-gradient coloring.** The panel resolves the inspected entity's TEAM
  gradient (player gradient for team 0, enemy gradient otherwise) and applies
  the SAME fixed indices the bottom bar + gear panel use (skill frame 3, skill
  icon 1, gear slot 5, gear item 1, cooldown overlay = `theme.darkest`). The
  entity's own `color_index` is for the body sprite, not UI - the panel uses
  the team gradient, not the entity's color_index.
- **Layout** (top to bottom): a 4×2 grid of `slot_size` skill slots (1-4 top,
  5-8 bottom, empty slots show the diamond marker, cooldowns show the wash +
  number - all from `collectSkillSlots`); then active effects as
  `small_icon_size` (128) icons flowing left→right then down (max 8 columns,
  OMITTED entirely when the entity has no effects); then the gear mirror
  (weapons row + gear stack + combat-stat column, same layout as
  `buildGearPanel`). The stat column LEADS with the entity's live combat
  state - `Current Health` (raw `current_health`) and `Aggro Range` (raw
  `aggro_range`) - before the shared gear-stat tail; the player gear panel
  shows only the gear stats.
- **Aggro-range world outline.** While the panel is open, `view()` also
  emits an `aggro_outline` tile overlay - the same Chebyshev square preview
  as the skill-range outline (extent = `2*aggro_range + 1`, theme lightest,
  8px thickness, drawn in full over gaps/edges), centered on the inspected
  entity. The world-space companion of the panel's Aggro Range stat row;
  levels only, pure over SessionState → replay-safe.
- **Effect icon source.** Active-effect icons in the UI (bottom-bar effects
  grid + entity-inspect panel) use the SKILL icon (`skills/<tag>`) when the
  effect shares a tag with a skill (EffectId and SkillId overlap: `reflect`,
  `stone_form`, `that_which_lingers`). The effect's own `effect_sprite` is a
  WORLD overlay (under `assets/effects/`), not a UI icon. Future non-skill
  effects will ship dedicated UI art; until then they fall back to the
  effect-sprite path or a magenta placeholder. See `effectIconSpriteId`.
- **Right-click input** (`handleRightClickInspect`, levels only) uses the
  same movement-threshold disambiguation as the inventory drag: a right-press
  on a world entity tile records a `PendingRightClick`; movement beyond
  `drag_threshold_pixels` cancels it (the press became a camera pan); a clean
  release toggles inspect (same → close, different → switch, none → open).
  It coexists with `handleCameraPan` - both record state at right-press (the
  pending right-click + the pan's press position/anchor), the pan engages
  and the pending cancels at the same threshold, and on a sub-threshold
  release the anchor clears (no offset was computed) while the
  pending right-click fires the inspect.
  Suppressed over blocking UI (same `blockingElementAt` check as the tile
  cursor + pan) so a right-click on a panel never inspects the world behind
  it. Hubs are excluded - inspection is level-only by design.

### Tips overlay

A full-screen modal on any screen (the credits structure: `blocks_input`
9-slice panel, Back bottom-left) showing ONE tip from data/tips.txt at a
time: a centered half-width wrapped text column with 128x128 prev/next
glyph buttons flanking it, and an n/N ordinal directly beneath the
header. Opened from the global top bar's `?` button
(top-right, mirroring options at top-left - `Action.open_tips`, a toggle
like open_credits; the `?` and the `<`/`>` are font glyphs, no icon
sprites). The `?` hides in the EDITOR - that corner is the Test/Validate
row, the one screen with UI already occupying the top-right (the
overlay itself stays legal there). The OPEN state is class-1 (`UiSurfaceId.tips` /
`isSurfaceOpen(.tips)`, the recorded `toggle_ui_surface` event); the VIEWED index is a view
affordance (`UiState.tips_index`, the settings_tab convention -
`Action.cycle_tips` + the `tips_direction` payload mutate it directly at
the input layer, off the undo timeline; wraps, no-ops on a single-tip
list). It is an overlay-stack member like any other (opens on top of
whatever is up; Escape pops it when topmost). The tips file: Metadata + a `Tips` section, one
`tip <prose>` entry group per tip (`parser.tips_sections` /
`tips_file_format_version` v1), loaded at startup through
`loadConfigWithFallback` (embedded + shadow) into the history
(`GameStateHistory.tips`, self-owned strings, freed by the deinit);
`view()` threads it as a parameter. A non-empty list gates the `?`
button; an empty-but-valid file leaves the panel as background + Back.

### Settings screen

A full-screen modal overlay (`GameState.ui_surfaces.isSurfaceOpen(.settings)`,
toggled by the recorded `Action.open_settings` → `player_toggle_ui_surface`)
with TWO content
tabs (`UiState.settings_tab`: **Settings** / **Keybinds** - tab buttons
under the header, `.select_settings_tab` + the `settings_tab` click-payload
variant; a switch is a view affordance off the undo timeline
and resets `keybind_scroll_offset`). Mirrors the load-save browser /
credits screen overlays: a `blocks_input` 9-slice panel, a Back button
bottom-left that closes it. The screen is reachable from TWO entry points,
both wired through `Action.open_settings`:

**The Settings tab** (the scalar fields) lays its 12 control rows out on a
TWO-COLUMN grid (6 rows per column, `settingsControlRowRect` - rows 0-5
left, 6-11 right): a single 12-row column needs 1792px where the region
between the tab row and the Back button has ~1610, and did even before the
tab row existed (the last row kissed the Back button); two columns also
fit the wide reference screen better. The control column must clear the
Back button - pinned by the tab-row test in settings.zig.

**The Keybinds tab** is the in-game rebinding UI (editing flows landed):

- Every row's COMBO area starts a LISTENING rekey (`KeybindTarget.binding`);
the row swaps to a highlighted "Press a key... (Esc to cancel)" panel. The
CAPTURE SEAM is the text-input model: while ANY edit is active
(`UiState.keybind_edit`), `translateInput` suppresses ALL binding
translation + routes raw presses into the edit (`ui.routeKeybindCapture` →
`KeybindCaptureOutcome`, resolved once per frame in `main.frame` →
`resolveKeybindCaptureOutcome`): the first non-modifier key press or mouse
press captures (a click ANYWHERE during listening binds the clicked mouse
button - standard capture behavior; modifier presses never capture, the
held modifiers become the combo's requirements); Escape cancels at every
phase (never captures).
- The row's ACTION PANEL opens the right-column action PICKER
(`KeybindTarget.binding`) - the full scrollable action list on the tab's
right half; picking one moves the row's combo to it → PENDING. The
standalone Add button (top of the list) opens the picker in add mode:
pick the action → listening → pending. A row's `+` adds a combo for its
action (listening → pending); an add's listening/pending row renders as
an extra row below its action's row group - where the confirmed combo
will appear (the display is action-sorted) - or at the top when the
action has no bindings yet, and the scroll clamps to keep the proposal
row on screen. The wheel scrolls the PICKER while it's open.
- PENDING: the proposal row shows the captured combo + the action panel +
Confirm/Cancel buttons (Enter CONFIRMS, Escape cancels - the
modal-capture-state convention, see Input) + the STEAL WARNING (warn
color): the scan
(`findKeybindSteal`) is `sameCombo` + `bindingContextsCoFire` (contexts can
be SIMULTANEOUSLY ACTIVE - NOT plain intersection: {anytime} co-fires with
{game} in-game though the sets are disjoint; the slice-2 loader scan
shared the wrong predicate until a slice-4 test caught it) + not the row
being edited; same action = a duplicate (confirming dedupes). Confirming
applies: rebuild `settings.input_bindings` (replace/append + REMOVE the
stolen entry - the loader's first-listed-wins rule, the edited row wins)
+ `markSettingsDirty` (the debounced persistence). X removes directly
(no confirm - Reset to Defaults is the safety net). All phases are pure
UiState (off the undo timeline); a tab switch discards an active edit.
- The whole editing UI rides ONE action (`.edit_keybind`) + the
`KeybindCommand` payload union as the click payload's `keybind_command`
variant.
- **Reset to Defaults** (bottom-right on both tabs, mirroring Back - a
whole-settings command, exempt from the keybinds-tab gate): direct click,
no confirm - the timestamped backup is the safety net. First backs up:
a synchronous flush (bypassing the debounce, so `settings.txt` is exactly
current) then a byte copy to `settings-backup-YYYYMMDD_HHMMSS.txt` in the
persistent root - the `backup_autosave` policy (best-effort, popup on
failure, the reset proceeds; same-second overwrite accepted - see File
System & IO). Then the whole `Settings` (every preference + bindings - no
identity data; the player name lives in the player save) is replaced by
the embedded `data/default_settings.txt` + `markSettingsDirty`; the
active edit + keybinds scroll clear.

Read side: one row per binding - modifier/key panels
("+" between; prettified ids via `keyIdDisplayLabel`: Ctrl/Shift/Alt,
KeyZ→Z, Digit1→1, left→LMB; never narrower than `keybind_min_panel_width`
- 9-slice panels render badly small, so single-char keys get a proper
button with a centered label) and the action panel DIRECTLY after the combo
(one row gap, no fixed column - the tab's right side stays open for the
slice-4 action-picker column) labeled "Action - Contexts" (the DERIVED
context set, `actionDisplayLabel` +
`contextSetDisplayLabel`, both comptime-generated from the enum/switch so
new members label themselves). NO group headers - the action name rides
in every row's action panel. Rows are sorted by action (declaration order,
stable) so an action's multiple combos sit adjacent. Scroll follows the
game-wide row-scroll convention: `keybind_scroll_offset` is the first
visible row, one wheel notch = one row (lower clamp at the input site,
upper clamp authoritative in `buildKeybindsContent`), whole visible rows
only. The wheel routing runs BEFORE the options-menu gate (the settings
overlay opens ON TOP of the options menu in-game - the slider-drag-
before-the-gate pattern) or the gate's return eats it.

1. The main-menu "Settings" button (opens settings directly over the main
   menu - the world is already idle there, so no pause concern).
2. The in-game options menu's "Settings" button (added to `buildOptionsMenu`
   in ALL contexts the options menu appears in - level + hub). Settings opens
   ON TOP OF the options menu (drill-in); Back from settings returns to the
   options menu, not the game. The options menu stays open underneath, so
   its top-of-`update()` gate keeps the world paused while settings is up -
   no separate gating for the settings overlay. This is the modal-overlay
   stacking rule from DESIGN → Modal overlays: each `blocks_input` panel
   shields the one behind it.

**The options menu is reachable everywhere, with per-screen content.**
The button list is derived from the current screen, so each surface gets
meaningful entries: level/hub/editor keep the pause-menu set (session
verbs + save paths + Settings + Exit to Main Menu), and the main-menu
variant carries the meta entries instead - Settings / Credits / Exit Game
(native only; a browser tab is the user's to close,
not ours). No variant carries a close button - a Continue button would
collide with resume-game meanings on some screens, and the `.escape`
action (Escape keybind + the top-bar options button toggle) is the close
path everywhere. The entry point is the top-bar options button, emitted on every
screen, plus Escape via the chain above. The main-menu's own stack holds
only the session-flow verbs + mode entries (Continue / New Game / Load
Save / Editor); Settings + Credits moved INTO the options menu (one
convention from every screen). Exit Game requests the quit via
`SessionState.quit_requested` - a request, not a state transform: the
game loop's exit condition consumes it, and the shutdown defers flush
pending writes + diagnostics. (History: this reverses an earlier decision
- Escape on the main menu was once a no-op because the menu's content was
session-only; the per-screen button lists removed that reason.)

**UI entries are per-screen so every label is unambiguous on its
screen.** When adding a button/panel entry, check its label against
everything else reachable on the same surface - a semantic collision
(the menu-close "Continue" vs the resume-game "Continue" that cost two
rework commits) is resolved at design time, not by playtest. Prefer
omitting an entry over shipping an ambiguous one; if no honest label
exists, the feature is usually in the wrong place.

**Control kinds.** Every field is one of:
- **Toggle** (bool): click to flip. `vsync`,
  `auto_skip_attack_step_out_of_combat`, `auto_target_at_cursor`, `show_fps`.
- **Choice** (discrete values): `camera_zoom` (4-button row: 25 / 50 /
  75 / 100 hundredths; 100 = 1.0× zoomed in, 25 = 0.25× max zoom out,
  default 50; the f32 lives at the render/input seam), `player_color_index`
  (6-swatch row: click a color square to pick; the swatches show the
  player-gradient colors so the value is visible).
- **Slider** (integer range, step 1): one `slider` `UiElement` variant
  serves ALL slider fields - there are no float sliders. `render_fps_cap`
  (0-256; 0 = "Uncapped" shown as a label, not a number), `animation_fps`
  (1-16), and the three volumes (`master_volume` / `music_volume` /
  `sound_effects_volume`, 0-100 - see "Volume integer migration" below).
  Interaction: click anywhere on the track → jump to the nearest step;
  press-and-drag along the track → scrub live; no keyboard slider control
  (the UI is mouse-driven throughout; keyboard focus is a deferred concern).

**Volume integer migration.** The three volume fields were f32 0.0-1.0;
they are now u32 0-100 (percentage, obvious on disk + in UI). This collapses
audio sliders onto the same integer-slider widget as the fps fields (one
control kind, not two) and moves the last floats out of `Settings` (a data
struct) to the backend seam: the backend's music-volume application /
`playSounds` convert `@as(f32, vol) / 100.0` immediately before the raylib
call. (The audio diff-and-apply snapshot was later removed - volume
scaling is applied per frame by `updateMusic`; see Audio.) AGENTS → Code
Style already restricts floats to input/settings/
rendering; this narrows it further - `Settings` is all-integer for scalar
fields except `camera_zoom` (u32 hundredths, a 4-choice 25/50/75/100; the
f32 lives at the render/input seam). Migration is
free pre-release (no real players; the taplop rename is itself pre-release):
`settings_file_format_version` 1 → 2; an old v1 user `settings.txt` is
rejected by the hard version gate → `loadConfigWithFallback` falls back to
embedded defaults + surfaces the warning popup → the next debounced write
persists v2. Parse clamps volumes to 0-100 (robustness vs hand-edited files).

**Field binding.** A `SettingId` enum (one per field) + a per-control
`SettingRef` carries `{ setting_id }` on slider / choice / toggle elements
so the input handler knows which field to mutate and how. The click
payload's `setting` variant is the click-to-cycle path for
toggles/choices (the load-save `save_row` pattern); sliders are
handled directly in the input handlers by hit-testing against the control
rect (drag state, like the camera-pan anchor). Settings live on
`GameStateHistory` (off the undo timeline - preferences, not gameplay), so
mutating them is a DIRECT WRITE in the input handler, not an event (same as
`ui_state` toggles) - replay-safe by construction.

**Persistence.** Every control mutation calls `markWriteDirty(.settings, ...)`
(the existing debounced-settings writer; 1s quiet / 5s max-wait). The
writer emits the full settings file in the v2 format. Native `run` defer +
web `beforeunload` flush on shutdown.

**Live-apply.** Most fields are read live each frame already (`camera_zoom`
by `view()`/`computeCamera`; `render_fps_cap` by
`renderIntervalMicroseconds`; `animation_fps` by `view()`), so a change
there takes effect next frame with no apply step. Audio + vsync need an
explicit apply. **Audio applies per frame with NO diff machinery**: the
backend's `updateMusic` scales every music layer by the current settings
each frame and `playSounds` reads the sfx volume per play (the old
snapshot + diff approach was removed when layered music landed - see
Audio). Input
handlers just mutate `history.settings` + `markWriteDirty`. **Render
resolution live-applies the same way** (`last_applied_render_resolution`
snapshot → `backend.applyRenderResolution`, which recreates the render
target; a failed apply reverts the setting + popup - see Platform Seam →
Render target resolution). **vsync does NOT
live-apply** - `rl.setConfigFlags` may not take effect without a window
recreate, so the vsync control shows a "(change requires restart)" label
and the setting persists for next launch; `applyVsync` is called only at
init (unchanged). **On web the vsync setting is a NO-OP**: the browser's
requestAnimationFrame paces rendering to the display refresh regardless -
rAF IS vsync on web, and no page code can render faster than it - so the
web label reads "(always on in browser)" and both the toggle and the
render cap can only ever render *slower* than refresh, never faster.


### Text input widget

The shared freeform-editing widget (first consumers: the editor
inspector's name/sprite/stat fields; later the settings screen's deferred
freeform-integer entry). Design:

- **Pure core, unit-tested:** `TextField` (ui/text_input.zig) - a fixed-capacity
  (128-byte) UTF-8 buffer with `length`, a byte-index `caret`, and a
  `selection_anchor`. All edit operations are pure methods over the
  struct (insert / deleteBackward / deleteForward / moveCaretTo with a
  `select` flag), so the editing logic is testable without raylib.
  Caret movement is CODEPOINT-aware (never splits a multibyte char).
  `moveCaretTo(index, select)` is the one movement primitive: click =
  `select=false` (clears the anchor), drag/shift+arrow = `select=true`
  (sets the anchor if unset, then moves the caret) - one primitive
  covers click-position, drag-select, and shift+arrow selection.
  Character FILTERING (digits-only for numeric fields) is not core -
  the input-routing layer knows the field kind and filters before
  insert.
- **Backend seam:** the backend drains the platform char queue each
  frame into a transient UTF-8 string on the polled input; the pipeline
  routes it to the focused field. The only raylib-side surface - the
  rest of the pipeline is headless-testable by injecting the string.
- **Focus model:** one focused field at a time, state on `UiState` (off
  GameState - transient like drag state; the COMMIT is the event, the
  buffer never needs replay). While a field is focused, ALL action
  translation is suppressed (chords too, ctrl+Z included - Escape
  first, then undo); the field's keys route to the buffer: chars
  insert, Backspace/Delete/arrows edit, shift+arrows select.
- **Resolution semantics (M2 + commit-on-dismiss):** Enter or the
  field's OK button COMMITS (validate/clamp, push the field's wrapper
  event, clear focus); Escape DISCARDS. The keyboard outcome resolves
  ONCE PER FRAME from `main.frame()` before the drain - a frame-level
  player action under the restricted exception in DESIGN → Architecture
  ("Frame-level player actions"), which also carries the obligation to
  record its own idle point. A click on another INSPECTOR
  control commits the old field and the click proceeds normally
  (one-click field switching). A click ANYWHERE ELSE (viewport, undo,
  tabs, palette) commits the old field and is CONSUMED as pure
  dismissal - a click outside the inspector mid-edit is either
  deliberate dismissal or a misclick, and placing an enemy or firing
  undo as a side effect of ending an edit is the surprising outcome.
  Corollary: Undo while focused commits the field and eats the click -
  the NEXT click performs the undo (commit-and-immediately-undo in one
  click would read as "undo is broken").
- **Render:** the field's builder emits the field element; `view()`
  adds the caret (a thin solid_rect positioned by measuring the prefix
  via FontMetrics) and the selection highlight rect for the focused
  field only.
