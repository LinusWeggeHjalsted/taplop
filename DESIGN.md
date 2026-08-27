# Ziglop — DESIGN

Settled subsystem design: architecture, invariants, the "why X is shaped this
way." Read on demand when you need the design behind something already built —
not every session. This file is the home for settled design prose; AGENTS.md
holds the "how to work here" rules and points here via the Subsystem Map. See
AGENTS.md → Documentation for the four-file lifecycle (open question → TODO;
settles → DESIGN; task completes → DONE). A fact lives in ONE place; AGENTS
never restates design — it points.

**Track the cost, not just the decision.** A settled decision's non-obvious
LIMITATION or downside belongs inline with the decision (a "Known limitation"
line or footnote). A decision that reads as clean in DESIGN can hide a real
cost (e.g. the InputBindings full-replace overlay silently shadowing new
default bindings for existing installs) until someone hits it. If a choice
trades a desirable property for another, say so at the decision site — don't
make the reader re-derive the tradeoff. A limitation that later becomes
unacceptable is the seed of the next slice; leaving it unrecorded means the
next session meets it as a surprise instead of a known.

## Platform Seam (raylib)

- raylib is linked ONLY into the native exe. Keep it out of the test build (and
  the emscripten build's shared code) by never importing raylib from any
  file the test-root scan pulls in.
- `src/main.zig` stays raylib-free. The game loop is platform-agnostic and
  SPLIT into a shared per-frame core + a thin platform driver:
  - `frame(backend, *FrameState)` is the deterministic core: poll input,
    compute camera, drain events up to a 10ms budget (see below), maybe
    render. NEVER yields/sleeps — scheduling is the driver's job. Called by
    BOTH platforms, so gameplay outcome is identical across native and web
    (event order + real-clock wait deltas match; only wall-clock drain
    duration differs).
  - `gameLoop(...)` is the NATIVE driver: a blocking `while (!shouldClose())`
    that calls `frame()` each iteration and yields (`backend.waitTime(0.1ms)`)
    when idle. The WEB driver (web.zig) replaces this with
    `emscripten_set_main_loop_arg(callback, ...)` — the browser schedules rAFs
    and handles yielding, so no sleep/asyncify.
  - `FrameState` holds the per-session mutable state that lives across frames:
    `history`, `previous_view_state`, `frame_arena`, `last_render_time`.
  The backend is duck-typed with `shouldClose()`, `deltaMicroseconds()`,
  `pollInput() PlatformInput`, `render(ViewState, ViewportSize)`, plus timing
  helpers (`realClockMicroseconds`, `renderIntervalMicroseconds`, `waitTime`,
  `applyVsync`). Entry is `pub fn run(backend, allocator, file_source, io)`.
- The drain is BUDGET-DRIVEN: `frame()` calls `update()` repeatedly while the
  stack is non-empty, no wait is active, and <10ms has elapsed — so a
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
  until it ends — not a concern for current workloads; revisit if a long-drain
  feature lands (see TODO PACING).
- `pollInput()` reads edges FIRST, then pumps (`rl.pollInputEvents()` after).
  raylib's PollInputEvents copies `previous = current`; on web, events arrive
  async via JS callbacks between frames (current is already set on entry), so
  pumping before reading would erase the edge (current == previous → no
  press detected). Read-then-pump works on both platforms (native gets ~1
  iteration of latency at the uncapped speed, negligible).
- `src/raylib_backend.zig` is the ONLY file that `@import("raylib")` (plus
  `native.zig` and `web.zig`, which import the backend). It owns the window, the real-clock
  (`rl.getTime` → microseconds for deltas + render gating), input polling
  (`pollInputEvents` each poll, independent of rendering), and rendering. Built
  with `SUPPORT_CUSTOM_FRAME_CONTROL` so `endDrawing()` only flushes the render
  batch — we call `swapScreenBuffer()` (vsync paces there) and `pollInputEvents()`
  ourselves, so the uncapped loop owns event polling. Without this,
  `endDrawing()`'s built-in `PollInputEvents` eats input events that accumulate
  during the vsync block (lost clicks).
- Rendering: all content is authored in the reference resolution
  (`types.reference_width` x `reference_height`). render() draws it 1:1 into a
  reference-sized `RenderTexture`, then blits that to the window LETTERBOXED
  (aspect-preserving, centered). Element `Color` is passed as raylib's
  DrawTexturePro tint — that multiply IS the grayscale×color theming path.
  Textures are lazy-loaded from `assets/<sprite_id>.png` and cached; MISSING art
  draws a magenta box (dev-friendly) instead of failing fast — the one place we
  deliberately don't panic, since absent art is a normal in-progress state.
- The reference↔window letterbox transform lives in one place
  (`viewTransform()`): render() uses it to blit, pollInput() inverts it to map
  the pointer back into reference space. Keep them in sync via that helper.
- `src/native.zig` is the native exe root (`pub fn main`): sets up allocator/IO/
  window/persistent-dir, then calls `main.run` with a `RaylibBackend`. Drives
  the shared `frame()` via a blocking while-loop (the native driver).
- `src/web.zig` is the web (emscripten) exe root: mirrors native but mounts
  IDBFS at /ziglop for persistence and drives `frame()` via
  `emscripten_set_main_loop_arg` (the browser schedules rAFs; no sleep/yield,
  no asyncify). The patched-stdlib web-build workflow lives in AGENTS → Build & Test.
- All three raylib-linked files (`native.zig`, `web.zig`, `raylib_backend.zig`)
  are excluded from the test-root scan in `build.zig` (`collectZigFiles`). If
  you add another raylib-linked file, exclude it too.
- raylib key ids are emitted in Web `KeyboardEvent.code` form (`KeyZ`, `Escape`,
  `Digit1`, `ControlLeft`, ...) to match `data/default_settings.txt` bindings.
- Coordinate space: `pollInput` reports the viewport AS the reference
  resolution and maps the pointer into reference space (inverse letterbox), so
  the whole game — UI hit-testing and screenToTile alike — works in reference
  coordinates.
- **Two cameras per frame.** `frame()` computes an INPUT camera (pre-update,
  reflecting the previously-rendered view — the player clicks against what's
  on screen) and a RENDER camera (recomputed post-update, before `view()`, so
  it tracks the state being drawn). Without the recompute, a move completed
  this frame draws the player at the new position under a camera still
  centered on the old one — a one-frame glitch. Both go through
  `view.computeCamera(state, zoom, pan)` so they never drift relative to each
  other or to the pan offset.
- **Camera pan (right-drag)** is transient view state on `SessionState`
  (`camera_pan` + `camera_pan_anchor`), off `GameState` — replay-safe by
  construction (like `tile_cursor` / the animation clock). Levels/hubs only;
  cleared on player move (recenter) and screen transition. `handleCameraPan`
  (input_handlers.zig) runs anytime (mid-wait / mid-turn), grabs the world
  point under the cursor at drag start (sub-tile float precision via
  `input.floatWorldPoint`, the float inverse of the camera transform), and
  solves for the camera that keeps it under the cursor. Pan-start is
  suppressed over blocking UI (`blockingElementAt`). Right mouse is the pan
  button (cancel is Backspace only).
- `build.zig` also generates `src/generated_lookups.zig` and the `generated`
  module (SkillId/EffectId enums) by scanning `src/skills/` and `src/effects/`,
  plus `generated_sprite_metadata.zig` (pixel dims from PNG IHDR for every
  shipped `assets/**/*.png`, keyed by sprite id) and `generated_assets.zig`
  (embedded content map). All are gitignored.

### SDF text outline (outlined text rendering)

Outlined text (damage/heal numbers, outlined UI labels) renders via a
**signed distance field** pipeline: a glyph atlas whose texels encode
distance-to-glyph-edge (positive inside, edge at alpha 128) instead of
coverage, plus a fragment shader that thresholds the field into fill +
outline band. One shader-driven `drawTextEx` per string — no per-string
CPU raster, no dilation pass, no texture cache (the pre-SDF approach was
an 8-direction drop-shadow ring: 9 draws, fuzzy at non-integer offsets,
no antialiased outer edge; kept as the fallback).

Key pieces (`raylib_backend.zig`):

- **Build-time atlas**: `tools/sdf_atlas_generator.zig` is a HOST tool
  linking raylib as a library (no window — SDF generation is pure CPU) that
  bakes the atlas via the SAME raylib calls the runtime once used
  (`loadFontData(.sdf)` + `genImageFontAtlas`) — zero metric drift. The blob
  (header + per-glyph metrics + atlas bytes) is embedded via the
  `generated_sdf_font` module; `initSdfTextOutline` parses it (microseconds)
  and assembles the `rl.Font` manually. This moved ~1.4s (release) of
  startup SDF generation to build time.
- **Encoding range**: raylib's SDF defaults encode only ±2px of distance —
  far too little for 8px outlines. The generator's raylib dep is compiled
  with `-DFONT_SDF_CHAR_PADDING=22 -DFONT_SDF_PIXEL_DIST_SCALE=6.0`
  (±21 atlas px, covering 8px at the smallest outlined size, 48px from the
  128px base atlas). `sdf_pixel_dist_scale`/`sdf_char_padding` in
  raylib_backend.zig must stay in lockstep (a `@compileError` + blob
  validation guard this; the blob carries its baked params and mismatches
  degrade to the fallback).
- **Shader**: embedded GLSL (330 on desktop, ES 1.00 on web — both variants
  in raylib_backend.zig, selected comptime). Thresholds the decoded field:
  `d >= 0` fill, `[-outlineWidth, 0)` outline band, `fwidth`-sized
  antialiasing (fixed smoothing on GLSL ES 1.00, no `fwidth`). Straight
  alpha out (raylib blends premultiplied-input as straight; the old
  raylib SDF example's shader outputs the same shape).
- **GRAY_ALPHA, not GRAYSCALE**: the runtime texture is reconstructed as
  GRAY_ALPHA (gray=255, alpha=SDF) because raylib swizzles GRAY_ALPHA to
  `(r,r,r,g)` on desktop GL — a grayscale texture samples `.a` as constant
  1.0 and renders solid boxes (this bit us once; the blob stores only the
  alpha channel and the runtime interleaves).
- **Fallback policy**: any init failure (blob invalid, texture upload,
  shader compile) logs a warning and flips to the 8-direction shadow ring
  — decided ONCE at init, fixed for the session. An SDF font must never be
  drawn without its shader (texels are distances, not coverage). A
  persistent-dir font shadow does NOT affect outlined text (the blob is
  baked from the shipped TTF at build time — accepted; shadowing is a
  side-effect seam, not a designed feature).

### Allocator rule for emscripten (no page_allocator on web)

`std.heap.page_allocator` is **unusable on wasm32-emscripten**: it is
BrkAllocator, which grows wasm memory via the raw `@wasmMemoryGrow`
intrinsic. Emscripten's JS glue only refreshes its heap views (HEAP8/...)
and SAFE_HEAP bounds when growth goes through ITS allocator (emmalloc
sbrk → emscripten_resize_heap). A raw grow leaves the JS side stale — the
views detach (JS access to wasm memory aborts) and SAFE_HEAP keeps the old
memory size (wasm access to the grown region reports a segfault). This was
the web black-screen regression: `loadFont` duped the TTF into grown
memory and the first stbtt read tripped SAFE_HEAP.

Rule: on emscripten, ALL allocations go through libc. Transient,
untracked allocations (font bytes, crash-dump output, existence probes)
use `transient_allocator.zig` — c_allocator on emscripten, page_allocator
on native. Never call `std.heap.page_allocator` directly from shared code.

## Audio

Sound is a **side effect**, never gameplay state. Same replay-safety rule as
file writes: event handlers queue sounds gated `!replaying`, so undo/redo
scrubbing is silent. The architecture mirrors `PendingWrite`:

- **`SessionState.pending_sounds: std.ArrayListUnmanaged(SoundId)`** (off
  the undoable GameState → replay-safe by construction; `backing_allocator`-
  backed, cleared each frame). Event handlers + input handlers call
  `session.queueSound(allocator, .id)`; `frame()` drains via
  `session.drainPendingSounds()` after the update drain and plays them through
  the backend. The `!replaying` gate is at the PUSH site, so replay pushes
  nothing.
- **`SoundId` enum** (types.zig) — one variant per sfx file under
  `assets/audio/sfx/` (15 shipped: move, weapon_swing, spell, damage, pickup,
  skip, equip, learn_skill, salvage, swap_skill, button_click_down,
  button_click_up, menu, defeat, mission_completion). Music is a single
  always-on stream, NOT a `SoundId`. **Sound names align with their trigger
  events where one exists** (move↔move, pickup↔pickup, equip↔equip, etc.); the
  one intentional divergence is `damage` (fired by the `attack` + `collision`
  events — many-to-one, no `damage` event so no name clash) and
  `weapon_swing` (fired by `use_skill` for weapon skills — renamed from
  `attack` so `attack` refers to exactly one thing: the damage-primitive event).
  The full map: `move_entity`/`move_player`→move, `use_skill`(weapon)→
  weapon_swing, `use_skill`(spell/cantrip/enchantment/curse)→spell,
  `attack`/`collision`→damage, `pickup_items`→pickup, `equip_item`→equip,
  `learn_skill`→learn_skill, `salvage_item`→salvage. Multi-hit skills fire one
  damage sound per `attack` (N hits → N impacts); if that becomes an audio
  mess, throttle in the backend's `playSounds` (per-sfx cooldown), NOT at
  trigger sites.
- **Button press/release model.** Button actions fire on mouse RELEASE, not
  press (standard UI behavior; drag-off cancels). `SessionState.pressed_button:
  ?Action` records the button under the press; release fires the action only
  if the release is over the same button. Press always queues
  `button_click_down`. Release queues: the generic `button_click_up` for
  actions WITHOUT a specific sound; actions WITH a specific sound (skip,
  swap_weapons, panel toggles, skill slots) get their specific sound from the
  input/event handler that processes the action — so no generic up (would
  double-play). Skill slots are special: auto-fire suppresses the generic up
  and lets the `use_skill` event's weapon_swing/spell play alone; the prepare
  (targeting) path plays `button_click_up` explicitly so the player gets
  feedback that targeting started. `releaseSoundForAction` (types.zig) maps an
  Action to its specific release sound (or null = generic up). Keybind-
  triggered actions queue their specific sound at the input-handler site (no
  click sounds, since no button was involved). `pressed_button` is transient —
  cleared on screen transition alongside `ui_state`/`tile_cursor`/`camera_pan`.
- **Backend (`raylib_backend.zig`):** `initAudio(settings)` opens the audio
  device, loads all sfx via `loadWaveFromMemory` + `loadSoundFromWave` from
  the `FileSource` (never the filesystem — same seam as textures), loads the
  music via `loadMusicStreamFromMemory`, sets it looping, starts it. A sound
  cache (`AutoHashMap(SoundId, ?rl.Sound)`) holds loaded sounds; missing
  audio caches null and skips play (like missing sprites → magenta, but for
  audio it's silent). `deinitAudio` (called from `deinit`) unloads everything
  + closes the device. If the audio device can't open, `audio_ready` stays
  false and ALL audio methods no-op — the game runs silent, never crashes.
  **MUSIC LIFETIME GOTCHA:** raylib's `LoadMusicStreamFromMemory` (stb_vorbis)
  keeps a POINTER to the passed buffer (no internal copy), so the bytes must
  outlive the stream — held in `music_data` and freed in `deinitAudio`
  alongside the stream unload. Freeing the bytes right after load (the
  texture-cache pattern) crashes on the next `updateMusicStream`.
  **MUSIC-MUST-LOAD-FIRST GOTCHA:** the music stream must be loaded + started
  BEFORE the sfx. `LoadSoundFromWave` converts samples to the active device
  format; if the music stream hasn't initialized the audio system's state
  yet, the sfx convert to a stale format and silently never play (no error,
  no log — the sounds load valid, `playSound` is called, but no audio). The
  order in `initAudio` is: open device → load+start music → load sfx. No
  compile-time guard — reordering silently breaks sfx.
- **Per-frame:** `frame()` calls `backend.updateMusic()` at the top (raylib
  requires it for streaming) + `backend.playSounds(drained, settings)` after
  the drain. Sfx volume = `sound_effects_volume * master_volume`; music
  volume = `music_volume * master_volume` (set via `applyVolumes`, called at
  init; re-call when settings change in the options menu).
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
  mission-start markers.
- **One-shot anims** (attack swings, hit flashes, death dissolves): the
  trigger lives in **event handlers** — exactly where one-shot sounds live
  (see Audio). A handler calls `session.queueAnim(allocator, PendingAnim{
  event_index, kind, duration_us })` gated `!history.replaying`, right next
  to its `queueSound` call. `frame()` drains `session.pending_anims` after
  the update drain (alongside `drainPendingSounds`), stamps `end_clock =
  animation_clock + duration_us` from the LIVE clock, and appends to
  `session.active_anims`. `view()` shows anims whose `event_index <
  current_event_index` (the triggering event is in the projected history —
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
    (player → player gradient, enemy → enemy gradient — same convention as
    weapon colors).
  - **Hit flash** (250ms): `hit_flash` kind, shows the `world/hit_flash`
    sprite (256×256, ported from the Unity project's 512×512 Hit.png at
    0.5x) centered on the defender's rendered art — horizontal frame center
    (entities are always horizontally centered) + vertical center of the
    opaque art bbox (midpoint of the `top` and `bottom` edges from
    `sprite_bounds`). Tinted with the active theme's `lightest` color (the
    artist's offwhite). Triggered by the `attack` and `collision` handlers
    **only when the defender takes nonzero damage** (a Reflect-zeroed or
    0-damage hit does not flash — the damage number still shows a "0"),
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
    by the `attack` and `collision`
    handlers; unlike the hit flash it shows even on a 0-damage hit (a
    fully-absorbed collision/attack renders a "0") so a connecting hit is
    observable — only the hit flash is gated on `incoming_damage > 0`.
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
    (gated `!replaying`) — once per entity per level (the handler skips
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
`verifyReplayMatch` (state.zig) compares *events* — the stack-top event about
  to dispatch vs. `event_history[current_event_index]` — via `deepEqual`. It
does NOT compare GameState fields after a handler runs. So a handler that
read the clock and wrote `entity.swing_end = clock + duration` into GameState
would be **impure** (its output would depend on wall-clock time, not just
`(state, event)`), and the divergent field would land silently in
`current_state` during replay — invisible nondeterminism, worse than a panic.
Also, the clock is on `SessionState` (off the snapshot timeline), so during
replay it holds the undo-time value, not the original-fire-time value → the
anim would re-play on undo (the behavior we explicitly don't want) and be
nondeterministic. The one-shot design keeps handlers pure by splitting the
trigger from the clock read: the handler pushes a `PendingAnim` carrying
only `{event_index, kind, duration_us}` (a pure side effect gated
`!replaying`, same shape as `queueSound` — it touches `SessionState`, never
`GameState`), and `frame()` is the ONE place that reads the live
`animation_clock` to stamp `end_clock`. So handlers never touch wall-clock,
the invariant stays a bright line, and the `!replaying` gate at the push
site is what prevents re-fire on undo/redo (replay queues nothing). This
mirrors Audio exactly: `queueSound` pushes a side effect gated `!replaying`;
`queueAnim` does the same with a richer payload. The only anim-specific
machinery is the `end_clock` stamp (the irreducible cost of being temporal —
a sound is done at push, an anim has to stay visible for a duration and
react to timeline scrubbing) and the `view()` event-index/time gating.

### The animation clock

`SessionState.animation_clock: u64` — accumulated session-relative
microseconds, off the undoable GameState → never in snapshots → replay-safe by
construction (replay doesn't render anyway). Advanced by `frame()` **pause-
gated** alongside the wait timer: when the world is paused (options menu /
pending error open), the clock freezes too, so anims freeze in place and
resume cleanly; when waits drain, anims advance. A fresh session starts at 0
so looping anims begin at frame 0 (raw wall-clock mod would start mid-loop).
One-shots store `end_clock = animation_clock + duration` in session-relative
units, so pause freezing also freezes one-shots mid-flight.

### Frame rate

`settings.animation_fps: u32 = 8` (Display section of `data/default_settings.txt`) is
the ONE global rate all anims share; frame duration = `1_000_000 /
animation_fps` microseconds. `view()` reads it (for the flag now; for one-shot
gating later). A future anim needing a different rate becomes a per-anim
override (deferred). A `0` fps is treated as the default (8) to avoid
divide-by-zero. It's a display/pacing preference (like `camera_zoom`), not
gameplay — not in snapshots, not touched by replay.

## Replay & Side Effects

- Undo/redo reconstruct past states by replaying the event history through
  `processEvent` (see `GameStateHistory.replayTo`). `history.replaying` is true
  during this.
- Event handlers must run **pure state transforms unconditionally**, but gate
  **observable side effects** (file writes/downloads, audio, dialogs) on
  `if (history.replaying) return;` so scrubbing history doesn't re-fire them.
- **Reconstruction reads** (level/hub/save config loads in start_level/
  start_hub/load_save) still run during replay — the rebuilt state depends on
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
  `GameStateHistory` next to `settings` — never deep-copied into snapshots,
  never touched by replay. Clean rule: **in `GameState` → change via events; in
  `SessionState` → change directly in the input/update path.** The screen-
  transition UI reset lives in the live loop (`gameLoop` clears
  `session.ui_state` when `screen` changes across `update()`, covering both
  event transitions and undo/redo across a screen boundary), NOT in
  `transitionScreen`. `input_state` is never reset — it is live hardware
  state. `tile_cursor` is the logical cursor (mouse or arrow-key driven);
  `auto_target_at_cursor` reads it in the input path, and the resulting
  `player_use_skill` event is what replay reproduces — the cursor value at
  prepare-time is never needed for reconstruction, so it's safe off GameState.
  Resolved per-frame in `update()` (`resolveTileCursor`): mouse-move drives it
  (with UI occlusion + tile validity), arrow keys nudge when the mouse is idle
  (snapping to the player tile if null).
- **Replay must not create events; new actions branch the timeline.**
  `processEvent` records into `event_history` only when `!replaying` (via
  `GameStateHistory.recordEvent`); the event index still advances (processEvent
  increments it before dispatch) so `replayTo`'s loop progresses, and each
  stack-top event is verified against the recording (`verifyReplayMatch`) —
  replay is strict-validation, not just rebuild. See Determinism & Tiebreaking →
  Replay VERIFICATION for the natural-stack machinery. Taking a new action
  after an undo discards the stale future first (`discardFutureTimeline`:
  trims `event_history` + `idle_points`, frees snapshots/checkpoints ahead of
  the branch), so the new action continues a fresh timeline from the undone
  position.
- **Undo mid-drain reverts to the current idle point.** Idle points (undo
  stops) are recorded only when the event stack EMPTIES — a player action's
  full subtree completing. So during a drain (e.g. enemy turns with waits
  after the player ended their turn), `current_idle_index` still points at
  the idle point BEFORE the drain started — the state the player was just
  at. `undo()` detects mid-drain (stack non-empty OR wait active) and
  reverts TO that current idle point (cancelling the partial drain via
  `discardFutureTimeline`) rather than decrementing past it (which would
  land one idle point further back than expected). The partial drain's
  recorded events are discarded — the action never completed, so there's
  nothing to redo. A second undo (now idle) decrements normally.

## Versioning

- `game_version` is the runtime "which build" stamp: `YYYY.MM.<commits-this-
  month>[-dirty]`, computed in `build.zig` (`computeGameVersion`) from the
  build clock + git and exposed to code via `@import("build_info").game_version`
  (a `b.addOptions` module wired onto BOTH the exe and test root modules).
  Git is optional/build-time-only (never a runtime dependency — the string is
  baked in): git ran → real count (a true `.0` is legitimate) plus `-dirty` on
  a modified tree; git absent/no repo → `YYYY.MM.unofficial`.
- `game_version` is ADVISORY: recorded into artifacts and warn-on-mismatch, not
  a hard gate (a hard replay-validity guarantee would need content-hashing the
  gameplay logic — future work). It is NOT `build.zig.zon` `.version`, which
  stays a static, vestigial package-identity `0.0.0`.
- Two orthogonal versions, both recorded in serialized artifacts:
  `file_format_version` (monotonic int per artifact, in its `Metadata` section)
  answers "can this parser read the file?"; `game_version` answers "will a
  correctly-parsed file behave in this build?".
- `file_format_version` is on EVERY config file type (levels, hubs,
  missions, campaigns, player saves, settings, color themes, player loadouts,
  session logs) — one monotonic int per type, in the file's `Metadata` section
  (the FIRST section, before any type-specific sections). The loader
  validates it as a HARD gate (`error.UnsupportedFileFormatVersion` on mismatch
  or absence) and discards it — it's a parse-time compatibility check, not
  runtime state (not stored on the parsed type). The save writer emits the
  current constant in a `Metadata` section. Per-type version constants live
  in parser.zig (`level_file_format_version`, `hub_file_format_version`,
  etc., all currently 1).

## Logging & Replay

(session-log read/write/reconstruct is built; combat-log projection is built;
combat-log UI rendering + replay-viewer UI still TODO)

- There is ONE log: `event_history` (see Replay & Side Effects). The session
  dump, the combat log, and the future replay viewer are all it plus
  projections — not separate capture systems.
- Session dump (ctrl+L → `dump_event_log` → `main.dumpEventLog`): serialize
  `event_history` to config format via `parser.writeEventLog` — a
  comptime-generic serializer over the `Event` union (lives in parser.zig with
  the other writers; new events need no changes). `Metadata` header carries
  file_format_version + game_version + created timestamp; an `EventLog` section
  holds one entry group per event (`event <category> <variant>` discriminator +
  one line per payload field; optionals omit their line when null;
  Vector2/Materials/slices space-separated). Events alone reproduce a session —
  do NOT also log player input (the input→event translation is deterministic
  and would be redundant/divergent).
- Reader: `parser.loadEventLog(sections)` → `SessionLog { file_format_version,
  game_version, created, events }`, the comptime-generic inverse.
  file_format_version is a HARD gate; game_version is advisory (caller warns via
  `main.warnIfSessionLogFromDifferentBuild`).
- Reload does NOT re-drive events through the input path. `event_history` is the
  fully-linearized event stream; `GameStateHistory.reconstructFromEventLog`
  deep-copies the loaded events into `history_arena` and drives the existing
  `replayTo`/`restoreTo` machinery (which forces each recorded event onto the
  stack in turn, discarding handler-pushed sub-events since those were
  themselves recorded — but VERIFIES them first via `verifyReplayStep`, see
  Determinism & Tiebreaking; verification runs even cross-session now). `idle_points` are NOT serialized — step
  boundaries are derived, not stored. The `runToIdle` +
  `reconstructFromEventLog` end-to-end test (main.zig) proves forward play ==
  replay.
- Combat log = a filtered PROJECTION of `event_history` (derived on demand,
  NOT stored on GameState — the old `CombatLogEntry`-on-`Level` scaffolding is
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

## Determinism & Tiebreaking

- Replay no longer papers over nondeterminism: the natural-stack replay
  loops (`replayTo` / `replayToWithIdleTracking`) let `processEvent`'s
  pop/push machinery run and verify each stack-top event against the
  recording (see Replay VERIFICATION below). A handler that pushes a
  different child than the original session did now panics instead of the
  state silently staying correct via force-fed recorded events. The old
  "replay is robust to nondeterminism" property is deliberately replaced by
  strict validation — the whole point. Determinism still matters for live
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
  next recorded event is a fresh top-level player action — the loop seeds
  it (top-level events come from player input, not handlers, so the
  recording is authoritative there and the check is trivial). Comparison is
  `deep_copy.deepEqual` (comptime-generic, mirrors `deepCopy`; no floats in
  event payloads → exact `==`). A mismatch is a fail-fast `@panic` naming
  the recorded index, both variant tags, and the first differing payload
  field (`deep_copy.firstDiffField` recurses through the union payload
  struct). Runs for ALL replay origins including cross-session
  (`reconstructFromEventLog`) — a divergence is a nondeterminism bug we want
  surfaced, not silently rebuilt state. (Cross-session replay of a custom
  mission whose files changed since the original session WILL panic —
  accepted as fail-fast; the reconstruction cache is deterministic for
  shipped content and within-session replay. Closing the custom-mission
  cross-session gap lands with cache serialization into the session log, the
  planned `file_format_version` 2 work.) **Semantic shift:** replay is now
  strict-verification, not robust-rebuild — a nondeterministic handler
  panics instead of the state silently staying correct via the recording.
  This is the point of validation. Idle-point derivation in
  `replayToWithIdleTracking` simplified: the real `event_stack.len` replaces
  the old virtual-depth bookkeeping (idle = stack empties). This is also the
  primitive the Online Services TODO wants for server-side replay validation
  (leaderboard anti-cheat).
- **Replay PLAYER-ACTION LEGALITY validation.** Two layers gate what a
  replay log can seed at an idle point (when the stack drains and the next
  recorded event is pushed as a fresh top-level event):

  1. **Structural whitelist (`isPlayerAction`)** — the OUTER gate. A fail-
  closed `switch` that returns true only for event variants a player can
  push at an idle point, `else => false` for everything else. This closes the
  spoof gap where a hand-crafted log seeds handler-internal machinery
  (`attack`, `turn_end`, `end_level`, `start_mission`, ...) at an idle point.
  The whitelist is a pure tag-check (no continuation inspection) thanks to the
  orchestrator convention (below): every user action maps to a single
  orchestrator event, and machinery events are never whitelisted.
  `player_skip_level` is additionally gated on `build_info.dev_mode`
  (dev-only build).

  2. **Context legality (`validatePlayerAction`)** — the INNER gate. Rejects
  player actions that were illegal at the recorded point: `player_move_action`
  (destination must be in `reachableTiles(...)` — full BFS, matches live);
  `player_use_skill` / `player_skip_move_to_skill` / `player_prepare_skill`
  (skill on bar + off cooldown + valid target); and the meta exit/skip
  orchestrators (screen must match — e.g. `player_restart_mission` only legal
  at `.level`, `player_exit_to_menu` at `.level`/`.hub`, `player_replay_mission`
  requires `last_completed_mission != null`).

  **Orchestrator convention.** Input handlers push orchestrator events;
  orchestrator handlers push machinery events as children. The whitelist =
  orchestrator events. This 1:1 mapping of user action → orchestrator event
  is what makes the whitelist a pure tag-check. The exit/skip paths used to
  push machinery directly (`end_level{continuation}`, `end_hub`,
  `open_main_menu`, `start_mission`) — those are now machinery-only (handler-
  pushed, never whitelisted, never seeded at an idle point), wrapped by
  `player_skip_level` / `player_restart_mission` / `player_exit_mission` /
  `player_exit_to_menu` / `player_replay_mission` orchestrators. New player-
  pushable events → new orchestrator → add to `isPlayerAction`.

  Both gates run in `replayTo` / `replayToWithIdleTracking` right BEFORE
  seeding a top-level event. Handler-pushed children never reach here (they're
  never seeded — their legality is enforced by the parent handler's own logic
  + `verifyReplayMatch` structurally). Fail-fast `@panic` for now (malicious
  replay = reject); a future viewer-facing load may soften this to the error
  popup, while server-side leaderboard validation keeps it hard. The legality
  LOGIC lives in bool-returning helpers (`isPlayerAction`, `isPlayerMoveLegal`,
  `skillOnBarAndOffCooldown`, `skillTargetLegal`) so it's testable without
  panic-catching infrastructure (Zig 0.16 has no `expectPanics`); the
  `validate*` wrappers are a thin panic-policy layer over them. This is the
  other primitive the Online Services TODO wants for server-side replay
  validation.
- Tiebreaking convention — every ordering/selection over equal keys must break
  ties EXPLICITLY (in the comparator) or by a documented scan order:
  - Entities: ascending `entity_index`.
  - Tiles: ascending `(x, y)` (A* `comparePathNodes` already does this).
  - Skills: slot order.
- `std.mem.sort` is UNSTABLE: a distance/priority-only comparator leaves equal
  elements in an arbitrary order — always add the secondary key (e.g. `turn_end`
  enemy ordering breaks distance ties by `entity_index`). A strict `<`/`>`
  accumulation loop that iterates in the convention's order already yields the
  right tiebreak (lowest entity_index / first slot); document it with a comment
  rather than restructuring.

## Input

- **Binding modifier match is subset, not exact.** A binding's modifiers are
  REQUIREMENTS, not an exact match: a plain binding fires regardless of held
  modifiers (so ctrl+key works for any plain-bound action — e.g. ctrl+Space
  skip with `force_attack_step`); a ctrl binding fires only when ctrl is held.
  `checkAction` skips only when a REQUIRED modifier is NOT held. This matches
  the button-click path (`applyAction` sets the action directly with no
  modifier filtering) so keyboard chords and clicks behave the same.
- **Hybrid precedence — most-specific chord wins, ties co-fire.** When two
  bindings share the same physical input (same key/button id), the one whose
  required modifiers are a SUPERSET (in count, all held) wins and suppresses
  the less-specific one: ctrl+Enter beats plain Enter. Equal-specificity
  bindings (same required-modifier count) CO-FIRE — disambiguation is by
  handler context downstream, not here. This is how the shipped ArrowUp /
  ArrowDown pairs work: `move_cursor_up` and `error_scroll_up` both fire on a
  plain ArrowUp; the pending-error popup branch consumes the scroll action
  and `return`s, so when no popup is up only the cursor action takes effect.
  `checkAction` / `isActionHeld` suppress a matching binding when another
  binding on the same input matches the held modifiers with strictly more
  required modifiers (`isSuppressed`, `modifierSpecificity`). No load-time
  collision validation today (the loader appends every binding; a same-combo
  different-action pair is a tie, which co-fires by design, not an error).
- **Synthetic key repeat is owned by the engine, not the OS.** A held key
  fires its first repeat after `key_repeat_initial_delay_microseconds` (300ms)
  then repeats at `key_repeat_interval_microseconds` (40ms), tracked in
  `InputState.key_repeat_state` and advanced by the real-clock delta passed
  into `translateInput`. Owning the cadence means players cannot gain a
  real-time advantage by twiddling OS key-repeat settings. Only the repeat
  whitelist fires on a synthetic edge: movement cursors, undo/redo, skip,
  error-scroll. Non-whitelisted bindings (skill slots, toggles, confirm/cancel)
  are press-only — `checkAction` is passed an empty `keys_repeated` slice for
  them so a held key never repeats. Mouse buttons have no repeat.
- **Replay safety.** Repeat state lives on `InputState` (off the undoable
  GameState), and the resulting actions produce the same events a single
  press would — replay records events, not input timing, so a held-key
  session and a tapped-key session record identical event histories.
- **Known minor caveat: drain multi-fire.** `frame()` passes one
  `player_input` to every `update()` in a multi-event drain (≤10ms budget).
  Edge-triggered anytime actions (undo/redo, cursor nudge) can therefore fire
  on each drain iteration within a single frame. For undo/redo this is
  self-limiting (the first undo clears the event stack, ending the drain); for
  cursor nudges it can burst a few tiles during a drain that overlaps a held
  arrow. Pre-existing for real key presses; repeat makes it visible on held
  keys too. Brief and harmless; revisit if felt.
- **Settings persistence (user preferences).** Shipped defaults live in
  `data/default_settings.txt` (embedded, read-only). User preferences live in
  `~/.ziglop/settings.txt` (persistent dir, same format). At startup the
  loader reads defaults, then overlays the user file: scalars per-field (user
  value wins, missing keeps default); InputBindings, if present, REPLACE the
  default binding set entirely (the user's bindings are authoritative —
  changing official defaults only affects players with no user file). Writes
  are FULL-FORMAT (all sections including InputBindings) so the user file is
  the same format as the defaults. `Settings.camera_zoom` is the first
  persisted preference; other tunable fields mark dirty as their UI lands.
- **Binding overlay semantics.** Per-action, not per-key-combo: a user file's
  binding for an action replaces the default's binding for that action
  (rebind = replace, not duplicate). One combo → one action is the INTENT
  (a same-combo different-action pair is a config error), but the loader does
  not validate it today — it appends every binding, and equal-specificity ties
  co-fire per the hybrid precedence rule above; one action → multiple combos
  (additive — skip can live on Space AND Enter). Changing an official default
  for an EXISTING action doesn't reach players who have a user file (their
  binding is authoritative, even if it was an old default they never
  deliberately chose — we don't interrupt their flow).
  **KNOWN GAP (settled fix, deferred — see TODO → InputBindings per-action
  migration):** the implementation today REPLACES the entire InputBindings
  set on any user file with an InputBindings section, NOT per-action. So a
  NEW default binding (e.g. skip_level) is invisible to any existing install
  with a settings.txt — the user file is authoritative for the whole section,
  shadowing the new default. The settled fix is full-set + migrate: keep the
  user file as the authoritative full set, but on load INJECT default
  bindings for actions the file doesn't mention (idempotent via the next
  debounced settings write). Actions the file mentions stay authoritative.
- **Debounced writes (`PendingWrite`).** A general debounce primitive on
  `SessionState` (settings, future editor autosave). `markWriteDirty(tag,
  write_fn, now)` coalesces by tag (a burst of changes → one write). Debounce
  1s + max-wait 5s: a dirty mark fires after 1s of quiet, or immediately if
  dirty for >5s (so a continuous stream can't starve the write forever).
  `session_clock` (non-pause-gated, on SessionState) drives deadlines so
  writes fire even while the options menu is open. `frame()` fires elapsed
  writes each tick; it's the live path (replay goes through restoreTo/replayTo,
  not frame), so the `!replaying` gate is automatic. Native `run` defer + web
  `beforeunload` flush pending writes on shutdown (web best-effort — same
  limitation as the crash dump; a change-then-immediate-tab-close may lose
  the last debounced write).

## Error Handling

A `@panic` (unrecoverable failure) dumps the live `event_history` to
`crashes/crash_YYYYMMDD_HHMMSS.txt` in the persistent dir before trapping —
see "Crash dump" below.

Two error classes, with different responses:

- **Unrecoverable** — OOM, broken invariants, the `current.level.?` force-
  unwraps, replay-verification mismatch, a shipped/embedded file failing to
  parse (a real bug). Response: `@panic` (fail fast). The game can't
  continue, or the *code* is wrong.
- **Recoverable** — an I/O or parse failure on content that is effectively
  user-supplied at runtime: custom missions, player saves, session logs, AND
  shipped files overridden via the persistent-dir shadowing (a player/dev
  drops a broken file at `~/.ziglop/<shipped-path>` and the embedded copy is
  never reached — so "shipped content can't fail at runtime" is false by
  construction, not by accident). Response: warn + degrade/revert, never
  crash. See the three contexts below.

Never silently swallow (`catch {}`) — a dropped result becomes a confusing
silent bug. Allocation panics are written inline (e.g.
`catch @panic("failed to append event")`); OOM stays unrecoverable. The
recoverable path surfaces failures to the player via the error popup, not
silently.

### Recoverable error surface (the popup)

`SessionState.pending_error: ?[]const u8` (off the undoable GameState, so
replay-safe by construction) carries a message; `view()` renders it as a
modal centered popup (`ui.buildErrorPopup`), appended last so it draws on
top. `Action.dismiss_error` (bound to Escape + Enter) clears it.
`handleAnytimeInput` gates all input when a pending error is set — only
`dismiss_error` gets through; `update()` pauses the game (drag/camera/wait/
idle blocked), mirroring the options-menu pause. The message is duped into
`history_arena` (durable across frames; overwrite leaks the prior bytes —
accepted, same unbounded-arena tradeoff as `event_history`).

### Three contexts for recoverable failures

1. **Startup config** (`session_setup.zig`): settings, color themes, weapon
   types, salvage. Shadow parse fail → fall back to the embedded copy + warn;
   embedded fail → panic (real bug). All four loaders use
   `loadConfigWithFallback` + `FileSource.readEmbeddedFile`; warnings are
   collected and surfaced as a single `pending_error` popup after the history
   is created.
2. **In-event reconstruction reads** (`start_mission` / `start_level` /
   `start_hub` / `load_save` / `open_editor`): these handlers return `!void`;
   a read OR parse failure is recoverable — `readReconstructionFile`
   propagates live read errors (a missing/unreadable file — e.g. a deleted
   autosave after the menu offered Continue, or a broken persistent-dir
   shadow of shipped content) instead of panicking, and the handler's
   `catch` turns it into `failReconstructionRead`. `processEvent` catches,
   the drain loop reverts to the last idle-point snapshot (guaranteed empty
   stack — `recordIdlePoint` only fires when `event_stack.len == 0`, so
   `restoreTo(last_idle)` replaces `current_state` wholesale with a
   stack-empty state, no clearing needed) and sets `pending_error`. OOM
   still panics. The other ~90 handlers stay `void` — invariant unwraps +
   gameplay logic failures are bugs → panic. (The cache-miss `@panic` in
   `readReconstructionFile` is a SEPARATE policy — it covers REPLAY cache
   misses, which are a bug or genuinely unrecoverable cross-session log
   reload, not live reads. Don't conflate the two.)
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
always points at a real committed position — a simple, robust invariant with
no "pending" state). On a handler failure mid-transaction, the drain loop
trims the failed transaction's recorded events
(`event_history.shrinkRetainingCapacity(current_event_index)`) and restores
the snapshot. **Known edge case:** if the player undoes, then triggers a
failing load, the redo future was already discarded by the first event's
`discardFutureTimeline` and is not restored — so redo is unavailable after a
failed post-undo action. Accepted: a minor UX asymmetry (no crash, no
corruption), in exchange for not restructuring the most determinism-critical
code (replay verification, the reconstruction cache's `current_event_index -
1` keying). The transactional alternative (defer append + discard to
transaction commit) was considered and rejected: its independent benefits
are marginal with no current consumer, and its costs land in replay-
verification code where a subtle bug is most damaging.

### Crash dump (panic → session log)

A `@panic` (invariant failure, OOM panic, replay-verification mismatch,
force-unwrap, safety check) dumps the live `event_history` to
`crashes/crash_YYYYMMDD_HHMMSS.txt` in the persistent dir before trapping.
`event_history` is always a complete real-time log (B-simple per-dispatch
recording), so a crash file carries every event up to the crash and is a
replayable session log (standard format, loadable by `parser.loadEventLog` +
`reconstructFromEventLog`) — just named `crash_*` instead of `session_log_*`.

- **Mechanism:** `src/crash_dump.zig` is a custom panic namespace installed
  as `pub const panic = crash_dump.panic;` in BOTH entry files (native.zig,
  web.zig — replacing web's prior `std.debug.simple_panic`). It mirrors
  simple_panic's full safety-check helper set, but `call` first prints the
  message to stderr, attempts the dump, THEN `@trap`s. A file-private global
  `crash_history: ?*GameStateHistory` is `install`ed by `main.run` (native)
  / `web.main` (web) at startup and `uninstall`ed at clean shutdown (native
  defer; web skips uninstall — tab close IS shutdown). null outside a session
  (e.g. a panic during startup config load) → the handler skips the dump.
- **Safety:** the dump uses `std.heap.page_allocator` for its OUTPUT buffer
  (never the game's arenas, which may be inconsistent at panic time). It
  READS `event_history.items` (history_arena-backed) — a panic is almost
  always a logic error, not heap corruption, so the arenas are normally
  intact. The io handle + persistent dir are entry-file-owned (independent
  of the game arenas), so reusing them is safe. Every failure in the dump
  path is swallowed — we're already crashing; the dump is a bonus, never a
  cascade.
- **Scope: Zig panics ONLY.** A raw segfault (wild pointer) bypasses this
  and goes straight to the OS — the arena/integer-only model makes that
  rare; a SIGSEGV signal handler is a separate, more invasive step we don't
  take.
- **Web is best-effort:** the IDBFS `syncfs` flush may not complete before
  the tab closes on a panic, so a web crash file may be lost (in-memory FS
  only for that session). Native is the reliable path. Accepted.

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
  - `readFile(allocator, path) -> []const u8` — reads against a normalized
    project-root-relative path (`"data/default_settings.txt"`, `"assets/world/tile.png"`).
  - `writeFile(path, bytes)` — writes to the persistent dir ONLY; rejects
    `data/`/`assets/` prefixes with a panic (shipped content is immutable
    from the game's perspective).

Read order (first hit wins):
  1. in-memory VFS — uploaded zips / fetched custom missions (transient; not
     wired)
  2. persistent dir — `~/.ziglop/`
  3. embedded map — `data/**` + `assets/**` baked into the exe at build time

A read of a shipped path with no persistent/VFS override hits layer 3. A read
of a save/log hits layer 2 (misses VFS + embedded). A read of a custom mission
hits layer 1 (VFS) or 2 (persisted custom_missions/), depending on how it was
acquired.

### Embedding

`build.zig` walks `data/` + `assets/` and emits `src/generated_assets.zig`
(gitignored, like `generated_lookups.zig` / `generated_test_root.zig`) with one
`@embedFile` entry per file, assembled into a
`std.StaticStringMap([]const u8).initComptime` map keyed by project-root-
relative paths. The build step re-runs every `zig build`, so new files are
picked up automatically; *content* edits to existing files require a recompile
(which `zig build run` does anyway). `@embedFile` paths are relative to the
emitted file's location (`src/`), so the generated entries use `../data/...` /
`../assets/...` — owned by the build step, not a caller concern.

### Persistent path

Default: `~/.ziglop/` (dotfile in `$HOME`, NOT XDG — chosen for player-
discoverability of saves/custom content over convention). Holds `autosave.txt`,
`saves/`, `logs/`, future `replays/` and `custom_missions/`. Overridable via
`--data-dir` flag / `$ZIGLOP_DATA` env var (dev, portable installs, tests);
the flag wins over the env var, which wins over the default. For dev work,
prefer `zig build run -- --data-dir <scratch-dir>` so session logs and
autosaves don't mix into your real `~/.ziglop/` play data.
macOS/Windows native paths are DEFERRED but the abstraction does not paint
us into a corner: each backend just builds the source differently in its
entry file. Web (emscripten) is WIRED: web.zig mounts an IDBFS slice at
/ziglop (IndexedDB-backed, survives browser close) and builds FileSource on
that dir — same read/write code path as native, just a different dir source.

### Autosave

The autosave (`saves/autosave.txt`) is the recovery path for a player who
exits mid-session: `end_hub` / `end_level` push `write_save{autosave_path}`
before discarding the world, so progress is never lost to a crash or quit.
A NEW game overwrites it on the first subsequent `end_hub`/`end_level` — so
starting a new game while an autosave is present would silently destroy the
old save. To prevent that, `start_new_game` pushes a `backup_autosave`
MetaEvent (handler-gated `!replaying`, same side-effect convention as
`write_save`) that, when an autosave exists, copies it to
`saves/autosave-YYYYMMDD_HHMMSS.txt` (timestamp from
`formatSessionTimestamp`, same `YYYYMMDD_HHMMSS` format the crash dump uses).
The push happens AFTER `loadCampaignAndPushHub` so `backup_autosave` lands
ON TOP of `start_hub` on the event stack (LIFO → runs first). Pushing it
before would let `start_hub` run first, and its `transitionScreen(.hub)`
clears the event stack — wiping `backup_autosave` before it ever runs.
The player can later load a backup by pointing `load_save` at it (the load
path is arbitrary, not hardcoded to `autosave_path`). Best-effort: a backup
failure surfaces the error popup but does NOT abort the new game — the
backup is preservation, not a prerequisite. Collision (two new games within
the same wall-clock second produce the same filename) is accepted — the
second overwrites the first, a scenario implausible enough not to warrant a
suffix counter. The backup is a pure file copy (read autosave bytes → write
at the timestamped path); no PlayerData decode/encode, so it can't corrupt.

### Raylib seam

`raylib_backend.zig` stays the ONLY file that `@import("raylib")`. The texture
cache switches from `rl.loadTexture("assets/{s}.png")` (filesystem) to
`rl.loadImageFromMemory(".png", bytes)` from `FileSource.readFile` →
`rl.loadTextureFromImage` → `rl.unloadImage`. The backend asks the source for
bytes; it never touches the filesystem directly. Same pattern holds for audio
later (`loadMusicStreamFromMemory` / `loadSoundFromWave`).

`native.zig` computes the persistent path (XDG override / flag / env / default),
constructs the `FileSource`, and passes it into `main.run`. `main.zig` and all
game logic stay path-agnostic.

### Modding by shadowing (side effect, not a designed feature)

Because the read order checks the persistent dir BEFORE the embedded map, a
player can drop a file at `~/.ziglop/<shipped-path>` to shadow shipped
content, or add new paths (e.g. `~/.ziglop/assets/weapons/my_new_sword.png`)
for new sprites/campaigns. This is a side effect of the unified-source
layering, NOT a designed modding feature: no policy on which paths are
overridable, no verification, no safe-mode flag. It's accepted as-is for now;
revisit and add structure (override policy, verification, a disable-for-
troubleshooting flag) only if modding becomes a real goal.

### Migration (done)

The migration described above is complete: `history.directory` is gone,
replaced by the `FileSource` on `GameStateHistory` plus a sibling `io:
std.Io` handle (kept separate because `std.Io` is broader than file I/O —
callers that need the clock, e.g. `formatSessionTimestamp`, read it directly,
not through the file abstraction). All call sites across `main.zig`,
`event_handlers.zig`, `input_handlers.zig`, `parser.zig`, and
`raylib_backend.zig` go through the source. Parser tests read `data/...` from
the embedded map, so the test build is hermetic. The VFS layer (layer 1 of
the read order) is the only piece still outstanding — it lands with
custom-mission support.

### Settings ownership (loadSettings is self-owned)

`parser.loadSettings` DUPES each `input_name` into the passed allocator, so
the returned `Settings` OWNS its `InputBindings` strings — it does not
borrow from the raw file buffer. This is the durable fix for the mangled-
settings bug (where `overlayUserSettings` freed `user_bytes` while the merged
bindings still borrowed into it) and the general direction for any loader
whose result outlives the bytes it was parsed from: make the result
self-owned so the caller may free the raw bytes immediately. When
`loadSettings` replaces a base's bindings (overlay path), it frees the base's
owned strings + slice — so re-overlay doesn't leak the old names.
`parser.freeSettings(settings, allocator)` frees a `Settings`' bindings
(strings + slice); used in tests under `testing.allocator`, never in
production (settings live for the session).

`loadConfigWithFallback` still leaks the raw config bytes + parsed sections
for process lifetime (it's generic over `T`, can't selectively free). After
the ownership fix the `Settings` it returns no longer references those bytes —
they're unreferenced garbage that stays leaked (fine, process lifetime). The
other loaders (levels, hubs, themes, etc.) still borrow into the leaked
bytes; making them self-owned is the same direction, deferred until a load
change lands. See AGENTS → Build & Test → Testing discipline for why the leak matters for tests.

### Reconstruction cache (deterministic replay over mutable files)

Reconstruction-read event handlers (`start_level` / `start_hub` /
`start_mission` / `load_save` / future `start_editor`) read config files whose
results become part of the reconstructed state. Without a cache, replay
re-reads from disk — fine for shipped content (immutable) but WRONG for
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
  a read error is PROPAGATED (recoverable — see Error Handling → context 2).
  **Replay** (`replaying`): binary-searches by event index, linear-scans within
  the event for the path, returns the cached bytes.
- The key is `(current_event_index - 1, path)` — `processEvent` increments
  `current_event_index` before dispatch, so the event under handling is at
  `current_event_index - 1` (identical in live and replay). A single handler
  may read several files; the path distinguishes them.
- **Cache-miss policy:** in-session undo/redo (`replayTo`) never misses — live
  play always cached before replay can reach the same index — so a miss is a
  bug → `@panic` (fail fast, never silently fall back to disk, which would
  reintroduce divergence quieter). Cross-session reconstruction
  (`reconstructFromEventLog`, flagged by `cross_session_replay`) starts with an
  empty cache because no live play ever ran; there a miss falls back to
  `file_source` and caches the result (establishing the cache retroactively).
  For shipped content the bytes match the original session; for custom
  missions they're whatever is on disk now — the known cross-session
  limitation until the cache is serialized into the session log.
- `discardFutureTimeline` trims cache entries ahead of a branch (monotonic by
  event index, so shrink from the end), alongside `event_history` /
  `idle_points` / snapshots / checkpoints.
- **Not serialized yet** (within-session only). Cross-session log reload
  needs the cache serialized into the session log (a new `ReconstructionCache`
  section, `file_format_version` → 2), pre-populated by `reconstructFromEventLog`
  before replay. This is the same property wanted for custom-mission shared-
  replay reproducibility (content-addressed / pinned version); lands together
  with custom-mission sharing. The current in-memory cache doesn't paint us
  into a corner — adding serialization is a localized change to the log
  writer/reader + `reconstructFromEventLog`.

Editor consequence: editor-open reads go through the cache → undo past
editor-open replays the reads → cache hits → original bytes, regardless of
later saves. Editor edits are events mutating in-memory mission/level state
in `GameState` (captured by `deepCopy`, undo/redo by construction). Editor
save-to-disk is a **side effect gated on `!replaying`** (same convention as
`save_game` / `dump_event_log`) → undo never re-writes files. No
editor-specific undo machinery needed.

## Custom Missions & Online Services

Custom missions are player-authored content that runs through the SAME
engine path as official missions. The framing is diegetic: a custom mission
is a "dream," accessed via a dreamguide NPC (guided meditation). Design is
settled; implementation is mostly pending (the VFS layer is the foundation).

### Dreams (custom missions in play)

- **A dream is a normal mission run**, NOT editor playtest. Rewards persist
  into PlayerData (gear/skills picked up carry back to the campaign). The
  editor's playtest/validate discard machinery is NOT reused — it stays
  scoped to the editor. A dream uses `start_mission` → `start_level` →
  `build_player_from_data` (sync campaign PlayerData in), and `end_level` →
  `build_data_from_player` (sync entity back out) → `end_mission`, exactly
  like an official mission. Custom missions ARE official content in spirit
  (the shipped campaign is one locally-bundled set showcasing all skills);
  the only differences are file source + return target.
- **File source:** the VFS layer (layer 1 of the FileSource read order) or
  the persistent `custom_missions/` dir, NOT the embedded map. This is the
  outstanding VFS piece from File System & IO.
- **Return target = where the player was when they opened the browser**, NOT
  the mission's authored `start_hub`/`end_hub` (those may name a hub that
  doesn't exist in the player's campaign). In-hub / in-world-map / in-level
  launch → return to `player_data.current_hub`. Main-menu launch → return to
  the main menu (don't drop the player into the campaign world via a dream).
  The `start_mission` event for a dream carries `start_hub_id =
  current_hub`; the exit guard overrides `end_mission`'s return accordingly.
- **Main-menu launch requires a save pick** (existing save or new game) before
  `start_mission` — you need a character to dream with. Reuses the existing
  `load_save` / `start_new_game` machinery; the browser feeds into it.
- **Edge case:** a brand-new player with no hub visited has `current_hub =
  ""`. A dream from main menu is gated on having a Continue-able save; from
  a hub you're already in one.

### Browser (the custom-mission selector)

- A new full-screen overlay (alongside `world_map` / `full_combat_log` in
  `FullScreenOverlayId`). Reachable from three triggers, one UI:
  1. The dreamguide NPC in any hub (diegetic entry).
  2. The main menu (a button alongside New Game / Continue).
  3. The world map.
- Tabs/content:
  - **Acquired missions** (already in the persistent `custom_missions/`
    dir) — click to start. Enumerated via
    `FileSource.listCustomMissions` (see below).
  - **Online browse** (fetch list from the database, preview metadata,
    download into the persistent dir) — only once online services ship;
    absent/disabled until then. Fetch-to-local-then-play so no active
    connection is needed after download.
  - **Import from file** (zip upload / local path) — the offline sharing
    path, always available, no account needed.
- **Folder convention:** `custom_missions/<id>/` where `<id>` is the folder
  name. Editor-generated and online-downloaded missions use `<uuid>_<slug>`
  (UUID generated at mission creation, stored in `mission_uuid` in
  mission.txt, stable across re-saves; slug derived from the display name).
  Hand-placed folders with any name are ALSO accepted (the id is whatever
  the folder is named) — generation/download follow the convention, reading
  tolerates anything. Two authors making "Skeleton Attack" get different
  UUIDs → different folders, no collision.
- **`FileSource.listCustomMissions`** (file_source.zig): enumerates
  `custom_missions/` in the persistent dir, returns `[]CustomMissionEntry`.
  Each entry: `id` (folder name), `name` + `level_count` (from mission.txt),
  `has_custom_assets` (true if the folder has any file beyond mission.txt /
  player.txt / level_*.txt), `author_turns: ?u32` (null = unvalidated, until
  the validation replay format lands). Folders without a readable
  mission.txt are SKIPPED (broken/half-installed missions aren't offered).
  Persistent-dir only (no VFS — the local collection is the source of
  truth; transient acquisitions persist into this dir first).

### Content identity

Two distinct IDs, serving different needs:

- **Content hash (local, derived):** SHA-256 over the mission's raw file
  bytes — `mission.txt`, `player.txt`, all `level_N.txt`, and any custom
  assets under the mission's folder. Canonicalization for v1: sort file
  paths lexicographically, hash each file as a path-prefixed entry
  (`<path>\n<bytes>`), concatenate, SHA-256. NO line-ending normalization
  for now (our files are authored consistently); tighten only if
  cross-platform drift shows up. The hash is a DERIVED property (computed
  on demand), not a stored field on Mission. It is load-bearing for replay
  pinning: a session log records the mission content hash, and on
  cross-session replay the exact version is fetched/cached so handler
  outputs match the recording (closes the reconstruction-cache cross-session
  gap — see Replay & Side Effects / Logging & Replay). This is pure local,
  no server needed, and is the first piece to build.
- **Publishable ID (server-assigned, stable across versions):** a UUID/slug
  assigned at publish time, with each version carrying its own content hash.
  A leaderboard entry pins to a version (content hash); a mission's profile
  page aggregates versions. Out of scope until the server seam lands.

### Turn counters + author medals

Two turn counters, incremented in the player's `turn_end` (entity_index 0)
handler:

- **Per-mission (`Mission.turns_spent`):** scopes a single playthrough. Used
  by the mission-complete screen for mission stats, and by the validation
  replay's author medal target. Discarded with the mission on exit (editor
  playtest/validate are discard-semantics, so it naturally doesn't persist
  there). Increments whenever the player's turn ends, in any mode.
- **Cumulative (`PlayerData.turns`):** lifetime turns across the campaign,
  for historical stats. SKIPPED in editor playtest/validate (guard:
  `current.editor == null`) — the editor session must not inflate the
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
faster tier (very low author times can make tiers collide — accepted edge
case). Multipliers live as constants in the file that uses them (the browser
UI / mission-complete screen, when those land). The author time itself lives
in the **validation replay file's metadata** (not mission.txt — keeps
mission.txt pure authored config; the author time is result data tied to the
replay that proved it). Medal derivation is a pure function of author_turns,
so the browser/mission-complete derive at display time. A mission with no
validation replay shows "unvalidated" (no medals). The validation replay
format is the session-log format + reconstruction cache (`file_format_version`
2), not yet built — so `listCustomMissions` shows "unvalidated" for all
missions until it lands.

### Balance bounds (parse-time, warn + clamp)

All gear-stat variables (health, defense, damage, speed, etc.) have UNIFORM
`max_*` constants (one set for ALL content — official + custom; "custom
missions ARE official content" supports uniform bounds). Every parsed
gear-stat field routes through `boundedU32`, which **clamps out-of-range
values to the max and appends a warning** (so the game stays playable + the
author is told). Parse time is the single chokepoint: enemy gear definitions in
level files ARE the loot table (enemies drop their entire inventory + equipped
gear + a skill tome per equipped utility skill), and that loot persists into
PlayerData — so bounding enemy gear stats at parse bounds what can ever enter
the campaign.

- Warn + clamp (not fail-fast panic) so a broken file doesn't crash the game —
  the player sees a popup naming the field, value, file, and max, then the game
  continues with the clamped value. Matches the recoverable-error policy
  (DESIGN → Error Handling): the warning surfaces via `setPendingError` (the
  same popup as key validation), and the clamped value keeps the game playable.
- Editor `validate` mode catches over-max stats pre-publish (the validator
  runs the mission; a warning = "fix your mission"). Local import catches it
  on load (honest "broken mission" feedback, same spirit as the magenta-box
  fallback for missing art — don't hide the problem).
- The constants live in parser.zig (the parse-time chokepoint): `max_weapon_damage`
  (10), `max_spell_damage` (10), `max_health_bonus` (10, for coat/gloves/
  pants/boots health bonuses), `max_defense_bonus` (5, coat), `max_gloves_damage`
  (5), `max_pickup_radius` (5, pants), `max_boots_speed` (2). Entity base
  stats (max_health, defense, speed, aggro_range) are NOT bounded — only gear
  stats. `boundedU32(value_str, max, field_name, file_path, warnings, allocator)`
  is the helper; a null `warnings` list clamps silently (the test path).

### Auth & the server seam (deferred)

- **Local-first always.** The editor saves a mission to the persistent
  `custom_missions/` dir (zip or folder) — a complete, shareable artifact
  you can hand to anyone, post anywhere. No account, no server.
- **Online upload is optional and gated behind auth.** "Publish to the
  database" is a separate action requiring a token; the server validates
  (runs the validation replay, checks the content hash), assigns the stable
  versioned ID, and lists it. Authors get a profile page; missions get a
  discoverable entry.
- **Acquisition is symmetric:** online fetch (needs the server but NOT an
  account — browsing/downloading is anonymous) vs. manual import (zip/file,
  no server). A player never needs an account to PLAY custom missions, only
  to PUBLISH them.
- **Auth model (real accounts vs. device-identity) is UNDECIDED** — only
  affects the publish action, which is the last thing to build. The
  local-first story doesn't depend on it. Decide when the server seam lands.
- **Server component is out of scope for the single-file exe** — a separate
  backend. The client only needs a thin HTTP fetch/submit seam + an auth
  token stored in the persistent dir.

## Clones (clone system)

A **clone** is a per-mission record saved to `PlayerData.clones` on mission
completion. It captures how efficiently the run converted pickups into
materials: `materials_collected` (the summed salvage value of every item the
PLAYER picked up during the mission — counted at pickup time, regardless of
whether the item was later salvaged, equipped, or kept) over `turns_to_complete`
(`Mission.turns_spent`). Future completions of ANY mission **harvest** from all
saved clones, paying out `rate * turns_spent` per material where
`rate = clone.materials_collected / clone.turns_to_complete` (integer division).
So a clone is a permanent, compounding material factory keyed by mission.

- **Keying.** Clones are keyed by `mission_uuid` (see Custom Missions & Online
  Services → Content identity) — NOT by mission name (names can be duplicated
  across custom missions or renamed). `Clone.mission_uuid` is the identity;
  `Clone.name` is a denormalized display label carried for a future clones-list
  UI that renders without re-reading mission files.

- **Pickup accumulator.** `pickup_items` adds `computeSalvageValue(item,` 
  `salvage_definitions)` to `Mission.converted_materials_collected` for each item
  the player (entity_index 0) actually places into inventory. Leftovers that
  don't fit stay on the ground and don't count. Non-player pickups don't
  accumulate. The salvage value is measured at pickup, independent of what the
  player later does with the item — keeping it still counts toward the clone's
  rate (the rate is "how efficiently did this run convert pickups into
  materials," not "how much did the player salvage"). The actual
  `salvage_item` event still adds materials to `player_data.materials`
  separately (unchanged).

- **Completion flow** (in `end_level`'s last-level `.default` branch, after
  the completion sound, before the trailing `end_mission` push):
  1. Read `mission.{uuid, name, turns_spent, converted_materials_collected}`.
  2. Find an existing clone by uuid. Compute `cloneIsStrictlyBetter` (Pareto:
     `new_rate >= old_rate` for all 5 materials AND `>` for at least one).
     Tied-zero materials (a mission that gives no cloth in either run) don't
     block — `0 >= 0` passes, and `0 > 0` is false so it isn't the strict gain,
     but a gain on any nonzero material makes the run strictly better.
  3. Gate the whole block on `turns_spent > 0` (div-by-zero guard for dev
     skip-through via `player_skip_level`).
  4. **Harvest** (`harvest_clones` SuperEvent): sum over ALL existing clones,
     per material `rate * turns_spent`, add to `player_data.materials`. The
     just-completed mission's new/updated clone does NOT contribute to THIS
     run's harvest (it pays out on future completions) — harvest runs before
     `save_clone_info` (LIFO).
  5. **Auto-save clone** (`save_clone_info` SuperEvent): if no existing clone
     OR strictly better, replace/append. Otherwise set
     `MissionCompleteInfo.overwrite_offered = true` and DON'T auto-save — the
     overlay offers a manual "Overwrite Clone" button (`player_overwrite_clone`
     PlayerInputEvent → pushes `save_clone_info` from the `MissionCompleteInfo`
     snapshot, since the `Mission` is gone in the hub).
  6. `MissionCompleteInfo` carries `{uuid, name, path, turns_spent,
     converted_materials, overwrite_offered}` so the hub-side overlay + the
     manual-overwrite orchestrator can reconstruct `save_clone_info` from the
     timeline info alone — the `Mission` is gone by the time the overlay
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
  (`PlayerData` mutation) reproduced on replay — no side-effect gating needed
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

## Architecture

- Elm-like: main (init), update (state transform), view (render)
- Event stack (LIFO) on GameState, processed one at a time. When empty, waits for player input
- **Events are generic state-mutation verbs, not skills.** Each event mutates
  one dimension of entity/level state (health: `attack`/`heal`; momentum:
  `change_momentum`; cooldowns: `change_cooldown`; position: `move_entity`/
  `swap_positions`/`knockback`/`retreat`; status: `stun`/`create_effect`/
  `end_effect`; world: `aggro_check`/`pickup_around`/`death`) — a basis set
  over the mutable fields. A skill is a recipe: its `useSkill` computes and
  emits a sequence of these generic events. All skill-specific cleverness
  (conditionals, multipliers, radius loops) lives in `useSkill`, never in a new
  event. Only add a new event when a skill must mutate a state dimension no
  existing event covers; prefer composing existing primitives. Reactive
  mechanics (e.g. Reflect) belong in the effect system, not as skill events.
  **Aggro + level-end are decoupled.** `aggro_check` (no payload) scans every
  inactive entity and activates it if it sees an opposing entity within ITS
  OWN `aggro_range` — self-centric, one event covers the whole level. Pushed
  at level start (single event, not per-entity) and after every `move_entity`.
  `check_level_end` (no payload) is the win condition: if the player is on
  `level_end` and no active enemies remain → push `end_level`. Pushed after
  `aggro_check` (LIFO → runs after, so newly-aggroed enemies are counted)
  and after `death` (killing the last enemy while standing on the exit ends
  the level without an extra move). Not pushed at level start (player spawn
  and level end are always different tiles).
  **Prefer composing an existing primitive over re-implementing it.** When a
  second event/skill does semantically what an existing one does, reuse the
  primitive (push the existing event) instead of re-implementing the
  behavior — this keeps all post-effects in one place. `swap_positions`
  pushes two `move_entity` events (so sound, momentum, pickup, aggro,
  level-end all fire uniformly); `aggro_in_radius` and `aggro_check` share an
  `activateEntity` helper so the aggro-indicator anim can't drift between
  them. Where you can't compose (different range source or team filter),
  extract the shared core into a helper and leave a comment naming the ONE
  intended difference. The seam between sibling implementations is where
  silent drift bugs live; composition removes the seam.
  Scalar-field primitives clamp (heal to max_health; momentum/cooldown at 0 via
  functions.applySignedDelta)
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
- Arena allocation for game state snapshots/checkpoints. Deep copy via comptime reflection
- Allocator model (all on `GameStateHistory`, see state.zig): `backing_allocator`
  is the gpa backing every arena. Two live lifetimes: `history_arena` — durable,
  unbounded, backs the append-only session log (`event_history` + `idle_points`)
  and holds deep-copied event payloads (event slices are the replay source of
  truth, so they must outlive `current_arena` resets); `current_arena` — owns
  all memory referenced by `current_state`, compacted at each idle point
  (`compactCurrentArena`: deepCopy into a fresh arena, free the old) so per-turn
  churn and exited levels/hubs are reclaimed. `processEvent` and the input
  handlers get their state allocator from `current_arena`; durable recording
  goes through `history.recordEvent` into `history_arena`. Never allocate live
  gameplay state into the gpa directly — it won't be reclaimed or replayed.
- Screen enum is authoritative for "where are we" — transitionScreen() handles cleanup
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
  which runs while the old world is still live — before `start_level`/
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
  are omitted and reload to null — never compact/reindex on load. The skill
  bar never holds duplicate utility skills: the `player_assign_utility_skill`
  handler searches `equipped_utility_skills` for the dragged skill and, if
  found in another slot, pushes `swap_utility_skills` (target ↔ existing)
  instead of `equip_utility_skill` (which would create a second copy); a drop
  onto the slot that already holds the skill is a no-op. Weapon skills
  (slots 1-3, derived from the equipped weapon) are a separate,
  non-overlapping set in shipped content, so the search is over utility slots
  only. Replay-safe by construction (the check reads GameState, which
  reconstructs identically on replay). Save loading does NOT deduplicate — a
  hand-edited / pre-rule save with duplicates is preserved as-is (the rule is
  enforced at the drag path, the only way duplicates enter live). Dragging a
  skill OFF the bar (drop on empty space, a non-ref surface, or a cross-domain
  ref like an inventory slot) clears the source utility slot — see DESIGN →
  Architecture. A release back on the source slot is a no-op (no self-clear).
- Derived-from-entity data has a single source of truth: skill-bar slot
  resolution lives in `Entity.skillInSlot` / `Entity.collectSkillSlots`, not
  duplicated per caller
- **Cooldown inheritance on skill/weapon swap.** Equipping a skill or
  weapon onto the bar sets the incoming skill cooldowns to `@max(outgoing,
  incoming)` — never lower, so a fresh swap can't bypass a cooldown that
  was ticking on the displaced skill. This is what restricts the player to
  their 5 equipped utility skills at a time: rotating a used skill out and
  a fresh one in doesn't reset the used one, and rotating it back in
  inherits its preserved (still-ticking) cooldown. Two sites:
  `equip_utility_skill` — the incoming skill's cd becomes
  `@max(old slot skill cd, incoming cd)`. The outgoing skill's cooldown is
  PRESERVED in `skill_cooldowns` (not cleared) — clearing it would reopen
  the cycle exploit (use A, swap out, swap back in, use again). Since
  `skill_cooldowns` is keyed by SkillId (not slot) and `turn_start`
  decrements every SkillId's cooldown (not just equipped ones), a
  preserved cd keeps ticking while the skill sits off the bar.
  `equip_item` (main_hand/off_hand) — `transferWeaponCooldowns` sets all
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
  (changes which skills are accessible, not which are equipped — a used
  skill stays on cd when it reappears in the other hand, no bypass).
- `current.level.?` (and similar) force-unwraps in level/sub-level event
  handlers are intentional invariant assertions (those events only run in a
  level; the event stack is cleared on screen transition). Prefer fail-fast
  over silently returning, which would hide the logic bug the unwrap catches

### Modal overlays (pause + shield pattern)

Full-screen modal overlays — the options menu, the error popup, the
mission-fail overlay, the mission-complete overlay — share a structure:
`view()` builds them when a condition is true (a SessionState flag, a
GameState field, or `pending_error`), the full-screen 9-slice panel is
`blocks_input: true` so `hitTest` shields the UI behind it, and the overlay
buttons carry `Action`s that dispatch via `handleAnytimeInput` (before any
`update()` gate) so they work while the world is paused.

**Two rules, learned the hard way:**

1. **Don't gate `update()` before `processEvent` when the trigger is set
   inside an event handler.** The options menu and error popup gate
   `update()` at the top (return early before `processEvent`) — that's safe
   because their triggers are set OUTSIDE the event drain: the options toggle
   is in `handleAnytimeInput` (before the gate), and `pending_error` exits
   the drain via the `load_error` break (not via the gate). The mission
   overlays are different: their triggers are set INSIDE a handler
   (`end_level` sets `last_completed_mission`; the `attack` handler sets
   `player.health == 0` and pushes `death`). A top-of-`update()` gate would
   block the remaining cascade events from draining — the player gets stuck
   mid-transition, and the unprocessed event keeps `event_stack.len > 0` so
   the render gate's `drain_in_progress` skips `view()` entirely (no overlay,
   no sound). The mission overlays DON'T gate `update()`; they rely on the
   `blocks_input` panel + idle-input self-gating (idle input only runs in
   player turn phases; a dead player or a just-completed mission isn't in
   one). If a future modal's trigger is set inside a handler, don't gate —
   or gate only the idle-input/drag branch, not `processEvent`.

2. **Derive modal overlays from undoable state when possible, so undo/redo
   handles them naturally.** mission_fail derives from
   `level.entities[0].current_health == 0` (GameState) — undo restores
   health, the overlay vanishes. mission_complete derives from
   `last_completed_mission: ?MissionCompleteInfo` (GameState field, on the
   undo timeline) — the info rides the `end_level → end_mission → start_hub`
   cascade as an optional field on those events; `start_hub` sets the
   GameState field; Continue pushes a `dismiss_mission_complete` event that
   clears it (on the timeline — undo re-shows, redo dismisses). Both fall
   out of undo/redo without special-case cleanup. Contrast: a SessionState
   flag (off the timeline) survives undo and needs manual clearing — that
   was the first mission_complete implementation, and the overlay stayed
   open on undo. Prefer the GameState-derived approach when the trigger is
   already in undoable state.

### Level Editor (building blocks implemented; UI pending)

A custom-mission editor. A mission is multiple sequential levels, so the
editor is focused on a mission with per-level tabs (quick swap to edit each
level) + a mission-shared palette of enemies/decorations. Lives on
`GameState.editor: ?Editor` (already a field, currently always null) — null
outside the editor so normal gameplay snapshots pay nothing; when populated,
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
    mission: Mission, levels: []EditorLevel,  // was []Level — now reference-based
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
playtest/validate — they're gameplay using the existing gameplay input/UI,
just with editor-scoped exit flow. The `.editor` screen scope is just
`{ editor }` (NOT `level` — the editor reads `editor.levels[]`, not
`current.level`); the `.level` scope includes `editor` so the dormant editor
survives the playtest/validate screen transition.

**Palette: transient, dedup-on-load, no on-disk file.** On `open_editor`, the
levels' inline entity/decoration definitions are deduped into `entity_types` /
`decoration_types` (`entityDefinitionsEqual` compares definition fields only,
not runtime/position). Placements store `(type_id, position)`. Editing a type
updates every placement referencing it — no propagation sweep. Save flattens
back to the existing inline level format (single format, backwards
compatible). **Unused types are lost on editor close** (accepted as cleaner) —
since save is inline, a type with zero placements has no on-disk trace.

**Player loadout: `player.txt` in the mission directory, persistent.** The
player isn't part of the enemy palette (it's not placed; the `!` in each
level's Layout is the spawn position, already parsed). The loadout persists as
`player.txt` (an Entity definition, same shape as an `EntityTypeDef.template`,
parsed via `parseEntityDefinition`). Editor-global: same player across all
level playtests. Visible metadata (someone picking up a custom mission sees
the author's loadout). All official campaign missions ship a `player.txt` too.
In-campaign play of a custom mission uses the campaign's PlayerData instead
(separate path, doesn't change the editor design).

**Editor edits ride the existing event system.** `EditorEvent` variants
(`editor_set_active_level`, …) mutate `current.editor.?.levels[level_index]`
or the palette directly — pure state transforms captured by `deepCopy`, so
undo/redo works by construction. No editor-specific undo machinery. Editor
save-to-disk is a side effect gated on `!replaying` (same convention as
`save_game` / `dump_event_log`) — files stay off the undo timeline.

**Playtest/validate framing (Option 2: separate framing events, minimal
exit guard).** `open_editor` / `close_editor` / `start_playtest` /
`end_playtest` / `start_validation` / `end_validation` are MetaEvents. They
own enter/exit; the gameplay events stay pristine. `start_playtest` calls
`instantiateEditorLevel(editor, N)` → a concrete `Level` (entity 0 from
`player_def` at `player_start`, each enemy from its palette type at its
placement, runtime fields reset), copies `editor.mission` → `current.mission`
(so gameplay handlers read unmodified), preserves the editor mode (only flips
to `.playtest` when entering from `.edit`, so validate's next-level
continuation via `start_playtest` stays `.validate`), transitions to `.level`,
and pushes `pushGameplayStartEvents(sync_player=false)` — **the player sync is
skipped** because the player is already fully instantiated from `player_def`
(normal gameplay's `build_player_from_data` would clobber it with the
campaign's PlayerData). `end_playtest` / `end_validation` discard
`current.level` + `current.mission` (discard semantics — playtest/validate
never write back to the editor's levels) and restore `screen = .editor`,
`mode = .edit`. Validation is the same shape but starts at level 1 and forces
a full playthrough; its per-level continuation is "next `start_playtest` from
`editor.levels` or `end_validation`."

**Exit guard (the minimal editor-aware seam).** `end_level` checks
`current.editor`: in `.playtest` it pushes `end_playtest` (instead of the
default next-level/`end_mission`); in `.validate` it pushes the next
`start_playtest` or `end_validation{success=true}`. `build_data_from_player`
is skipped in editor mode (playtest/validate are discard-semantics — the
player's real PlayerData is unchanged). `end_mission` also guards: if an
editor is active, suppress the `start_hub` continuation (defensive —
`end_level`'s guard should redirect before `end_mission` is ever reached).
No other gameplay handler knows about the editor.

**Replay & the reconstruction cache.** `open_editor` reads mission.txt +
player.txt + all level_N.txt via `readReconstructionFile` (cache-deterministic).
`buildEditorMission` (pure, no I/O) does the dedup. In-memory instantiation
(`start_playtest` calling `instantiateEditorLevel`) is an event mutating
`GameState` — captured by `deepCopy`, deterministic by construction, no cache
concern.

**Editor UI layout (settled design; implementation pending).** Three-zone
layout + a left inspector:

```
┌─────────────────────────────────────────────────────────┐
│ [Level 1] [Level 2] [Level 3]⟷   [+]        [Test][Validate] │  tabs + primary actions
├──────────────┬──────────────────────────────────────────┤
│              │                                          │
│  Inspector   │           Level Viewport                 │
│  (left bar,  │      (rendered as in-game;              │
│   toggleable)│       clickable for paint/place/select) │
│              │                                          │
├──────────────┴──────────────────────────────────────────┤
│ [Select][Tile] [Enemies ▾] [Decorations ▾] [Items ▾] ⟷  │  tool palette (bottom bar)
└─────────────────────────────────────────────────────────┘
```

- **Tabs (top):** one per level, horizontally scrollable when too many for
  the width. Each tab carries a close button (×) that deletes the level
  (`editor_delete_level` event), shifts subsequent levels down, decrements
  `mission.level_count`. Gated on `level_count > 1` (a mission always has
  ≥1 level — deleting the last is disallowed). The "add level" button (`+`)
  is pinned OUTSIDE the scroll region so it's always reachable; it creates
  a level from the default template (`data/default_level.txt` — a minimal
  `!=` layout, `!` at (0,0), `=` at (1,0), no floor). `editor_add_level`
  event. Tab label: the level's name or "Level N" if unnamed; a color
  swatch from `color_wheel_index`.
- **Level viewport (center):** the active level rendered as in-game (tiles,
  decorations, entities, ground items, `!`, `=`). Click behavior is FULLY
  MODAL on the active tool (see below) — no dialogs, no mode-switching
  prompts; the active tool determines what a viewport click does.
- **Tool palette (bottom bar):** mirrors the in-game bottom bar's slot
  style. Fixed tools first ([Select] [Tile]), then three collapsible groups:
  Enemies, Decorations, Ground Items. Each group is a horizontally
  scrollable row of `slot_size` slots; each slot renders the type's full
  sprite stack (base + layers, colored via the enemy gradient for enemies,
  world gradient for decorations — same draw path as in-game). Each group
  has an "add new" button (`+`) at its tail that creates a new empty type
  via an `editor_add_*_type` event. Collapsed groups show just their header
  (expand/collapse toggle). Hover tooltips on slots show the type's name.
- **Inspector (left bar):** shows TYPE fields for the currently-relevant
  type (see selection model). User-toggleable (button in the bottom bar,
  mirroring in-game panel toggles), open by default. Auto-opens on new
  enemy/decoration/item creation (an empty type isn't useful until
  populated). NO DIALOGS anywhere — all field editing is inline within the
  inspector: sprite selection (scrollable/searchable list of shipped +
  mission-folder sprite ids), skill assignment, gear equip, stat fields,
  footprint editing (decorations), etc.
- **Primary actions (top-right):** Test + Validate buttons. Test =
  `start_playtest` on the active level (single-level); Validate =
  `start_validation` (full playthrough from level 1). Both transition to
  `.level` screen with editor dormant; `end_playtest`/`end_validation`
  return to `.editor`. The bottom bar during playtest/validate is the
  in-game bottom bar (the screen transition handles it; `view()` branches
  on screen). Upload/Publish UI is DEFERRED (lands with online services).

**Active-tool model (fully modal).** The active tool is always exactly one
of: {selection, tile-paint, enemy-type-X, decoration-type-X,
ground-item-type-X}. Selecting a palette slot sets the active tool to that
type and the inspector shows that type's fields. A viewport click's effect
is determined by the active tool:
- **Selection tool:** click selects / shift-click adds to / drag-marquee
  builds the selection set (heterogeneous `Selectable` set, see below).
  Placing does NOT happen in selection mode.
- **Tile-paint tool:** click/drag toggles floor tiles at the cursor
  position (paint floor / erase — right-click or a modifier for erase).
  Does not modify the selection set.
- **Placement tools (enemy/decoration/item type):** click places one
  instance of that type at the cursor position (pushes an
  `editor_place_*` event). Placing does NOT select the placed instance —
  you switch to the selection tool to select. (Auto-select-after-place is
  deliberately NOT the model; keeps tool responsibilities disjoint.)

**Selection model (`Selectable` union).** The viewport can contain
heterogeneous selectable things; multi-select is a REQUIRED feature
(marquee + shift-click). A `Selectable` union covers all kinds:

```zig
Selectable = union(enum) {
    tile: Vector2,                   // a floor tile (paint/erase target)
    entity_placement: usize,         // index into editor.levels[i].entity_placements
    decoration_placement: usize,     // index into decoration_placements
    ground_item_placement: usize,    // index into item_placements (new editor placement type)
    player_start: void,              // the '!' — singleton, movable not deletable
    level_end: void,                 // the '=' — singleton, movable not deletable
};
```

The selection set is `[]Selectable`. **Inspector tool-type inference:** when
the selection contains only placements (entity/decoration/item) that all
share one `type_id`, the inspector switches to that palette tool and shows
its type fields (editing the type updates all placements of it). When the
selection spans multiple types, or includes tiles / `player_start` /
`level_end`, no single type is inferred → the inspector shows selection
info (count, bounds) instead of type fields. Selecting `player_start` shows
the player loadout fields (`player_def`, reached by clicking the `!`, NOT by
a palette entry — the player isn't a placed type, it's a singleton spawn).
`player_start` and `level_end` are NEVER deletable, only movable (updating
the level's `player_start`/`level_end` via an editor event). Multi-select
that includes them is allowed for move/bounds but they have no type to edit.

**Ground items (new editor palette).** Levels already support loose floor
items via the `Items` section + layout char code (`GroundItems{position,
items}`). The editor gains a third palette group (Ground Items) for placing
single items not tied to an enemy — the level designer's custom loot.
Placements store `(type_id, position)` into an `item_types` palette, same
reference model as enemies/decorations. (The `Item` union's shape means the
item palette types are richer than entity/decoration types — weapon vs
skill-tome vs material vs gear — to be fleshed out when the item palette is
implemented.)

**Viewport hit-testing.** The selection tool needs click → `Selectable`.
Priority follows the render order (topmost-drawn = topmost-selectable):
entities over decorations over ground items over tiles; `player_start`/
`level_end` are selectables at their tile. Derived from the view drawable
list (decorations selectable through their full bbox, not just footprint —
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
`player.txt`.

**Event structs DEFINED, handlers PENDING.** Every edit-verb event struct
exists in events.zig (`editor_add_level` / `editor_delete_level` /
`editor_set_tile` / `editor_set_level_name` / `editor_set_level_color_wheel`
/ `editor_set_level_custom_theme` / `editor_set_mission_name` /
`editor_set_player_start` / `editor_set_level_end` / `editor_add_entity_type`
/ `editor_add_decoration_type` / `editor_add_item_type` /
`editor_delete_type` / `editor_place_entity` / `editor_place_decoration` /
`editor_place_item` / `editor_delete_*_placement` / `editor_move_*_placement`
/ `editor_set_entity_*` (20+ field setters) / `editor_set_decoration_*` /
`editor_set_item_*` / `editor_add_*_layer` / `editor_remove_*_layer` /
`editor_set_*_layer`), but `handleEditorEvent` is a `@panic` stub — every
edit verb except `editor_set_active_level` (handled inline in `processEvent`)
traps. Wiring the handlers is part of the UI slice.

**Pending:** editor UI/input — the layout + active-tool + selection model
above, implemented as a vertical slice (static shell first: tabs + viewport +
bottom bar + inspector rendering with real data, no interaction; then wire
input per tool + the edit-verb handlers). Still-needed event structs:
`editor_toggle_inspector` / `editor_set_tool`. Default level template
(`data/default_level.txt`). Validation result + replay attachment (deferred
with online services), editor autosave (nice-to-have).

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
following `sprite`/`color_index` pairs belong to that layer until the next
`layer` or end of entry. The base's own `sprite`/`color_index` are top-level
keys on the entry (the base owns the footprint).

**Sprite id convention: bare stems.** All config `sprite` values store the
BARE STEM (e.g. `tree_1`, `skeleton_1`, `player`), not the full asset path.
The code prepends the asset folder (`entities/{s}` for entities,
`decorations/{s}` for decorations, `weapons/{s}` for weapons, `skills/{s}`
for skills). Custom decorations use a stem like `custom/<mission>/<name>`
which lands at `decorations/custom/<mission>/<name>`. The comptime
sprite-metadata table (dims) is keyed by the full asset-relative path, so
the parser's `resolveDecorationSpriteDimensions` prepends `decorations/`
before the dims lookup.

**Derived, not stored:**
- **bbox** = sprite pixel dimensions / 256 (tiles_w × tiles_h). A footprint
  coordinate outside the bbox → parse error (fail fast).
- **anchor** = bottom-most-then-left-most footprint tile. The decoration's
  placement position (the layout char) is the anchor tile. Non-anchor footprint
tiles are implicit in the layout (space = no tile, so they're automatically
tile-free); the parse-time check catches a `.`/`!`/`=`/enemy char colliding
with a footprint-covered world tile.

**Placement invariant (parse + editor).** A world tile under a decoration's
footprint must NOT also be a level/hub tile — decorations sit on top of tiles
only via non-footprinted overhang. The parser rejects this at load; the editor
blocks placing a decoration whose footprint overlaps an existing tile and
blocks placing a tile under a decoration footprint.

**Rendering: split per bbox tile, sort by assigned footprint y.** The sprite
is split into one `DecorationPieceDrawable` per **bbox** tile (9 for the tree:
footprint + 7 overhang). Footprint is NOT used to decide what gets drawn —
overhang tiles still draw — it's a layout-reservation field only.

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
`y` and sits between them — rare; decide by looking at it in view()). Open
edge case: tall multi-`y` footprints with overhang between pillars (no such
art today; revisit if one ships).

**Color.** Each decoration base and each layer carries a `color_index` into
the current theme's **world gradient** (`world_gradient.colors[0..5]`). Tiles
use indices 1 and 3 (checkerboard); the background uses 2; so decorations
should use 0, 4, 5 for well-designed distinction. Default `color_index` = 0
(omitting the key is legal and yields the lightest world color). The resolved
color is passed as the raylib `DrawTexturePro` tint — that multiply IS the
grayscale×color theming path (same as entities/tiles).

**Multi-sprite layers.** A decoration may have a BASE sprite (owns the
footprint) plus zero or more LAYER sprites, each colored independently and
drawn over the base in declaration order (base first, then layers in file
order). Use case: a tree with a trunk (base) and a canopy (layer) colored
differently. A layer's graphic MUST be the same pixel dimensions as the base
(validated at load — fail fast on mismatch); the per-bbox-tile split and
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
`character_code`/position — those are per-level). Used ONLY as editor-palette
prefabs for "add new decoration." Existing decorations already in the
mission's levels populate the palette at editor launch via the existing
dedup-on-load (same as enemies). Custom decorations carry their footprint
inline in the level file (same format), so official and custom share ONE
parser path; the registry is never read during gameplay/replay, only when the
editor adds a new prefab to the palette. Loaded by
`parser.loadDecorationRegistry` (returns `[]DecorationTypeDef`).

### Occlusion inset (readability for overhang)

A decoration with large overhang can fully occlude an entity / ground items /
flag pole drawn behind it (the overhang bbox tile sorts at the footprint's y,
so it draws after — and on top of — anything on the tiles it covers). The
fix is a thin INNER outline of the occluded thing, drawn over the
decoration, so the occluded silhouette reads through without the decoration
receding (it stays fully opaque and visually in front — "something continues
behind here," not "the tree faded").

**Inner-outline mask = morphological dual of the outer outline.**
`generateOutlineMask` dilates with a DISK structuring element (offsets with
dx²+dy² ≤ t²), producing the OUTER band (transparent pixels within
Euclidean t of an opaque pixel; opaque stays transparent). The INNER band is
the dual: opaque pixels within t of a transparent pixel; transparent stays
transparent. The disk SE is not separable — a single 2D pass,
O(|band pixels| × |disk|), instead of the square (Chebyshev) SE's O(w·h·2t)
separable path — but the mask is cached per sprite (built once), so the cost
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
dilating — required for the INNER band, because dilation doesn't distribute
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
- **Ground items:** single sprite (1-element stack — the degenerate case).
`generateCompositeOutlineMask` decodes each sprite, ORs its alpha (alpha > 16)
into a frame-sized opaque mask (honoring `flip_horizontal` +
`source_rectangle`), then dilates. `OcclusionInsetDrawable` carries the
`[]const StackSprite` + frame dims; the backend's `getCompositeInsetTexture`
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
decoration stays fully opaque — the inset never makes the tree translucent.

**Occlusion gate.** The inset draws ONLY when actually occluded (otherwise
every entity gets a permanent rim). For each non-decoration ground entry E
(entity / ground items / level-end / mission-start marker), find any
decoration piece D drawn AFTER E (greater in the `groundEntryBefore`
`(sort_y, sort_x)` order) whose screen rect overlaps E's screen rect. If
yes, emit one inset draw for E. O(entries × decoration_pieces) per frame,
small constants — fine at current caps.

**Scope.** Occluded things: entities, ground items, level-end + mission-
start markers. Occluders: decoration pieces only (not tall entities over
short entities — deferred; the test is generalizable). The entity silhouette
includes base + body layers + weapons (composited — see above); gear and
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
colored independently, drawn after base and before weapons). The player
(team 0) uses `settings.player_color_index` into the **player gradient**
(overriding the entity field at render time); enemies (team != 0) use their
own `color_index` into the **enemy gradient**. Entity layers resolve into the
same team gradient as their base. `entityDefinitionsEqual` compares
color_index + layers for editor palette dedup. **Weapons** are team-gradient
index 1 (player → player gradient, enemy → enemy gradient) and are suppressed
when the entity's `displays_weapons: bool` is false (e.g. wolves); parsed
from `displays_weapons true|false` in the enemy definition (default true).
**Health bars** are always-on, drawn above the entity's actual art top (same
opaque-bbox scan as the skill-icon anim — see DESIGN → Animation). The scan
is a full `SpriteBounds { top, bottom, left, right }` (one decode per sprite,
cached in the backend as `sprite_bounds_cache`, threaded through
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
player's chosen index — the UI palette is independent of the player's body
color). Bottom bar: inventory/gear/skills buttons = 4; health globe
background = 5, fill = 1, border = 3; skill slot backgrounds = 3, skill
icons = 1; skip button background = 5, skip icon = 1; turn-step indicators =
3; momentum display = 3; weapon swap = 3. `view()` passes `active_theme` +
`settings.player_color_index` to `buildBottomBar`; the helper resolves colors
and threads them through `emitSkillButton`/`emitIconButton`.

## Memory & Budget

Arenas are NOT fixed size: they grow from a backing allocator
(ArenaAllocator → DebugAllocator → page_allocator → OS/wasm). Allocation
fails only when the backing fails: OS OOM (native, rare) or wasm
`memory.grow` hitting the module maximum / 4 GiB wasm32 ceiling (the
realistic case). Caps are estimates for now, to be tuned from real
measurements (see TODO.md).

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
- **Generous safety ceiling (~256–512 MB)** so runaway bugs (infinite event
  push, bad deep copy) fail fast at a `@panic` instead of killing the tab.
  Not a tight fit — real non-asset usage is single-digit MB for normal levels.
- **`event_history` grows unbounded** (every event, tens of bytes each) to
  power infinite undo. Accepted: growth is tiny, the feature is worth it,
  extreme sessions fail-fast rather than corrupt.

### Asset memory (from the Unity project audit)

Disk size is NOT memory size. Textures are the dominant consumer (~30× the
PNG folder once decoded), not gamestate: GPU needs raw RGBA = w×h×4. Source
art has ALREADY been downscaled to display resolution (the Unity audit's
lever 1 is done): weapons are 512×640 single-pose (~1.3 MB decoded), the
flag banner is 2048×512 (4 MB, an 8-frame sheet). Current assets: 94 PNGs =
1.9 MB on disk, ~60 MB decoded RGBA (~80 MB w/ mipmaps). Audio shipped as
OGG (DESIGN → Audio): 15 sfx (~220 KB) + a 3.3 MB looping music stream.

Two separate budgets:
- **wasm linear heap** — gamestate / events / decoded SFX / temp; small.
- **GPU/texture memory** — browser-managed on WebGL, large, art-driven, off
  the wasm heap. Streamed music also stays off the heap; fully decoded audio
  lands on it.

Levers, in impact order (1–2 DONE; the rest are future work):
1. **Downscale source sprites to display resolution** — DONE. Weapons at
   512×640, flag at 2048×512, entities 512×640, tiles 256×256. Decoded RGBA
   is ~60 MB, reasonable for web.
2. **Stream music as OGG** (raylib `LoadMusicStreamFromMemory`) — DONE.
   Music streams from the OGG bytes (tiny ring buffer + decoder vs the full
   PCM on the heap); the bytes stay resident for the stream's lifetime (see
   DESIGN → Audio → MUSIC LIFETIME GOTCHA).
3. **SFX:** fully decode to PCM (memory trivial); OGG only helps download.
4. **GPU texture compression** (ASTC/ETC2/BC via KTX2/Basis) only if later
   measurements demand it — lossy, WebGL/raylib support fiddly.

Web download budget: art is ~1.9 MB PNG + ~3.4 MB OGG audio (music dominates;
streamed at runtime but still downloaded).

## UI Framework

- `view()` builds a `ViewState` each render from a per-frame arena (reset every frame in the game loop); everything the ViewState points at lives until the next frame
- UI is a flat `[]const UiElement` (tagged union: nine_slice_panel, slot, button, text_label, fill_sprite, image), appended in back-to-front draw order — no sorting
- Builders (`buildBottomBar`, etc. in ui.zig) take a `bounds: Rectangle` and append into a shared `std.ArrayList(UiElement)`; everything positions relative to `bounds`
- Layout is Rect algebra: `Rectangle` has pure methods (`position/right/bottom/centerX/centerY`, `translate`, `inset`, and 3×3 `place*` anchors like `placeCenter`, `placeBottomCenter`, `placeCenterRight`). Plus `screenRect()`, `rowWidth()`, `Row`, `Grid` helpers in ui.zig
- Screen-space dimensions (widths/heights/sizes/offsets) are `i32` (rendering, not gameplay). Gameplay quantities (health, counts) stay `u32`
- Buttons carry an `Action` (same enum as keybinds) so clicks feed the one input path; skill buttons map slot 1-8 → `skill_slot_N`. Slots are for inventory/gear items only
- Cooldown = semi-transparent overlay image + centered number TextLabel (not a fill fraction). Health globe = `FillSprite` (two sprites: empty drawn whole, full cropped to fraction)
- `highlighted: bool` on Button/Image = reusable edge highlight (renderer outlines opaque pixels); used by the active turn-step icon, selected panel buttons, etc.
- Standard gameplay button/slot is `slot_size` (256 at 4k reference); `ui_gap` (16) between top-level items
- **Text coloring.** `ui.default_tint` (pure white) is the default `color` on every UI element. For sprites (Button/Slot/Image) it means "no tint" (show original art). For TEXT it's the "unset" sentinel: the renderer's `drawTextLabel` substitutes the active theme's `lightest` (the artist's offwhite) so uncolored text inherits the theme without builders needing a runtime color. Explicitly colored text (via `ui.colored(...)`) passes a non-`default_tint` color and is unaffected. Damage/heal numbers (`floating_text`) already pass `active_theme.lightest` explicitly at their call sites. The substitution is text-only — sprite tints keep `default_tint` = "no tint."
- **Text measurement seam.** `ui.FontMetrics` (raylib-free value type: `base_size` + `[95]i32` per-ASCII-glyph advances) is the single layout-side authority for text width. The backend extracts it from the loaded `rl.Font` (`RaylibBackend.fontMetrics`) and threads it through `RenderContext.font_metrics` into the builders. Its contract: **mirror the renderer's cursor advance exactly.** `measureSpanWidth` reproduces `rl.drawTextEx`'s per-glyph step (`advanceX × font_size/base_size + spacing`, float-accumulated), so laid-out width == drawn width and multi-span emit (`x += measureSpanWidth`) flows like one continuous string. The shared `glyph_spacing_font_divisor` constant is the one source of truth for the spacing both read — any new draw parameter the layout needs to know (letter-spacing, kerning) must be added there, not re-derived in the seam. Vertical: **center on the `font_size` glyph cell, stack on `lineHeight`** — raylib draws a glyph from the top of a `font_size`-tall cell, so centering that cell (not the 1.2× `lineHeight` box) puts the visual mass on the element's center; `lineHeight` is for multi-line y-advance only.

### Entity inspect

The enemy-inspect middle panel (`buildEnemyInspectPanel`, opened by right-
-clicking a world tile with an entity — levels only) is a READ-ONLY mirror of
the player's skill bar + active effects + gear panel. It shares the middle-
panel band + `middle_panel_height` with inventory/gear/skills; which entity
it shows is `UiState.inspected_entity_index`.

- **Read-only by construction.** Every slot is an `.image`, never a `.slot`
  or `.button` — so no `SlotRef` (not draggable from/to) and no `Action`
  (not clickable). Tooltips still work (`.image` carries `tooltip`; `tooltipAt`
  hit-tests it). This is the seam: the inspect panel reuses the bottom bar /
  gear panel's visual recipe but swaps the interactive element type for an
  inert one with the same sprite + tint.
- **Team-gradient coloring.** The panel resolves the inspected entity's TEAM
  gradient (player gradient for team 0, enemy gradient otherwise) and applies
  the SAME fixed indices the bottom bar + gear panel use (skill frame 3, skill
  icon 1, gear slot 5, gear item 1, cooldown overlay = `theme.darkest`). The
  entity's own `color_index` is for the body sprite, not UI — the panel uses
  the team gradient, not the entity's color_index.
- **Layout** (top to bottom): a 4×2 grid of `slot_size` skill slots (1-4 top,
  5-8 bottom, empty slots show the diamond marker, cooldowns show the wash +
  number — all from `collectSkillSlots`); then active effects as
  `small_icon_size` (128) icons flowing left→right then down (max 8 columns,
  OMITTED entirely when the entity has no effects); then the gear mirror
  (weapons row + gear stack + combat-stat column, same layout as
  `buildGearPanel`).
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
  It coexists with `handleCameraPan` — a no-movement right-press sets both
  the pan anchor + a pending right-click, and on release the anchor clears
  (no offset was computed) while the pending right-click fires the inspect.
  Suppressed over blocking UI (same `blockingElementAt` check as the tile
  cursor + pan) so a right-click on a panel never inspects the world behind
  it. Hubs are excluded — inspection is level-only by design.

