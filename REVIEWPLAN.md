# Ziglop - Full Codebase Review Plan

Purpose: a complete, systematic review of everything in the repository -
all ~108k lines of Zig across 145 files, the four project docs (AGENTS /
DESIGN / TODO / DONE, ~27k lines), the build system, scripts, data files,
and tests. The review flags **issues** (bugs, design drift, debt, doc-code
mismatch, style/convention violations) and calls out **things that are
well made** (patterns worth keeping as precedents, unusually clean seams,
sound invariants) with equal attention. A review that only lists problems
teaches nothing about what to protect.

Ground truth for "what the project intends": AGENTS.md (working rules) +
DESIGN.md (settled design). The review checks the code against the docs
AND the docs against reality, in both directions.

---

## Method

**Reading**: every file in its part is read in full (no sampling in src/;
the only sampled file in the whole review is DONE.md - 18.5k lines of
history, sampled for lifecycle conformance rather than proofread).

**Machine checks** run once up front and referenced throughout:
- `scripts/test.sh` (the authoritative pass/fail; exit code, not text)
- `zig build` (native), `scripts/web.sh` (web compile)
- `scripts/dash_sweep.sh --check` (prose punctuation gate)
- `scripts/doc_symbol_check.sh` (doc ↔ code symbol staleness)
- `scripts/unused_pub_report.sh` (dead/unused pub surface)
- `zig fmt --check` on the tree (should be clean if fmt discipline holds)
- Regenerate each machine-derived report (art / sound / gradient) and diff
  against the committed copy - committed hand-edits to derived files are
  drift by the project's own rule.

**Severity scale** (applied to every finding):
- **Critical** - likely player-visible bug, data loss, replay/save
  corruption, or a broken core invariant (purity, determinism).
- **Major** - real debt or drift: settled design violated, doc names a
  lie, invariant that holds only by luck, structural problem that will
  compound.
- **Minor** - local polish, consistency gap, small simplification.
- **Nit** - taste-level; noted so it's on record, not argued for.
- **Highlight** - well-made: a seam, test, invariant, or convention worth
  protecting and imitating. Every part aims for at least a few of these;
  they carry the same weight as Critical findings in the final synthesis.

Findings cite `file:line` (or doc section) so you can jump to each one.

**Project-specific review lenses** (from AGENTS/DESIGN, applied everywhere):
- Purity: handlers are `(state, event) -> state`; side effects gated
  `!replaying`; transient state off GameState; clock read only in `frame()`.
- Integer-only gameplay logic; floats confined to input/rendering/settings.
- Minimize `pub` (unused pub is presumed dead API).
- Comments describe code AS IT IS; no TODO/FIXME markers in code (TODO.md
  owns forward-looking notes); `//!` headers on architectural files.
- Belong, don't fit: adapters/shims/one-consumer flags are smells.
- Determinism + tiebreaking conventions; replay verification round-trips.
- Config-layer conventions: OOM panics inline, input errors return with
  errdefer cleanup; self-owned loaders leak-checked under
  `testing.allocator`.
- Doc lifecycle: a fact lives in ONE place; TODO `[x]` items collapsed;
  no stale symbols in backticked dot-paths.

**Security lens** (standing; findings mostly land in Parts 5, 12, 15).
A single-player local game has a small attack surface, but this project
has three real untrusted-input surfaces - custom-mission zips / Import
Game bundles / session-log bundles (parsed data from other people once
the online-services plan lands), player saves from disk, and the planned
server that will REPLAY attacker-submitted validation logs. Checked
specifically:
- Zip robustness: path traversal (zip-slip) in `zip_reader.zig` entry
  names, decompression/archive-bomb guards, allocations sized from
  untrusted counts.
- Path hygiene: does stem-namespace normalization actually block `../`
  and absolute paths in mission stems + custom-asset paths; persistent-dir
  shadowing paths built from config data.
- Numeric robustness: `asU32`-family overflow on huge tokens; raw config
  integers that reach slice sizes / indices without balance bounds;
  integer overflow in gameplay math per optimize mode (Debug panics,
  ReleaseFast wraps silently - which mode actually ships natively + on
  web is itself checked). Known candidate: material accumulation has no
  saturating clamp yet.
- Panic-as-DoS posture: every panic site reachable from untrusted data
  (tampered logs, malicious missions) classified - fail-fast is a fine
  LOCAL posture, but the server-revalidation plan changes the calculus;
  the review makes the posture visible so it can be decided on purpose.

**Performance lens** (standing; findings mostly land in Parts 4, 7, 13).
Turn-based so frame budget is generous, but the specific spots:
- Per-frame allocation discipline: the per-frame arena is the pattern;
  anything allocating per-frame OUTSIDE it (e.g. `sprite_bounds` as a
  frame-arena `StringHashMap` rebuilt every frame) is flagged.
- `view()` full rebuild per frame + the known-but-unmeasured web
  frame-time dips (TODO tracks them; the review reasons about where the
  cost must live and what to measure).
- `deepCopy`/snapshot/undo cost, A* per enemy per turn, AI `EvalFrame`
  work at the documented caps (max_entities=256, ~10k tiles).
- Each accepted-not-measured TODO item (stripe-scope-per-tile flushes,
  mouse-owns-the-frame, etc.) gets a reasoned verdict, not silence.
- Texture/asset memory on web (the wasm budget levers in DESIGN →
  Memory & Budget).

---

## Parts

Each part = one PROJECTREVIEW.md section, written and delivered before the
next part starts, so you can read along. Order is docs-first (they define
the review criteria), then core-outward, then the sweeps that only make
sense against the whole tree, then synthesis.

### Part 1 - The docs, first pass (~8.4k lines + DONE skim)
- AGENTS.md (822), DESIGN.md (6,301), TODO.md (999), README.md (81),
  plus the four derived reports (art 247 / sound 238 / gradient 97 -
  checked for derivation, not proofread). DONE.md (18,498) is SKIMMED
  only - it is purely history, never a review target for content, and
  never modified; the skim assesses one thing: whether the archiving
  discipline itself could be improved (entry shape consistency, how
  findable the history is, whether the one-liner/collapse convention
  actually held across sessions).
- What's checked: internal consistency (does AGENTS restate design it
  shouldn't? does DESIGN hold working rules it shouldn't?), doc-lifecycle
  conformance (`[x]` items collapsed to one-liners, settled questions moved
  to DESIGN, no prose duplication across files), TODO accuracy against the
  actual tree (does "DONE" code exist? does "open" code not exist?),
  readability/scannability, whether AGENTS is still loadable as a
  session-start file or has grown into a reference.
- Also: README vs the project's actual state (it's the only file a
  stranger sees).
- Doc claims that can only be settled by reading the code are recorded
  here as OPEN and resolved in Part 14 (the second docs pass).

### Part 2 - Core kernel: types, events, state (~11k lines)
- `types.zig` (3,993), `events.zig` (1,624), `state.zig` (3,581),
  `deep_copy.zig` (242), `functions.zig` (891), `tween.zig`.
- The game's spine: GameState/History, undo/redo/replay timeline,
  snapshot ring buffers, `validatePlayerAction`, entity model +
  getEffective* math, A*/chebyshev, the deep-copy/equal machinery behind
  replay verification.
- Lens: invariant soundness (the ~26 `current.level.?` force-unwraps
  question is live in TODO - the review forms an independent opinion),
  integer-only discipline, ring-buffer FIFO property, whether the event
  hierarchy is coherent or accreted, naming vs the verbose convention.

### Part 3 - Event pipeline + handlers (~7k lines)
- `event_handlers.zig`, `event_push.zig`, `handlers/meta.zig` (870),
  `handlers/level.zig` (1,563), `handlers/player.zig` (475),
  `handlers/player_input.zig` (1,366), `handlers/shared.zig` (257),
  `crash_dump.zig` (333), `combat_log.zig` (215).
- The update half of the Elm loop. Lens: purity + side-effect gating at
  every push site, the checkpoint policy, the editor arm's inline cases,
  orchestrator-vs-verb convention, `!replaying` gate correctness (incl.
  the vestigial-gate item TODO already tracks - independently confirmed),
  wait/pacing handling, undo-mid-drain safety.

### Part 4 - Skills, effects, AI (~13k lines)
- `skill.zig` (203), `effect.zig` (332), `skill_helpers.zig` (743),
  `ai_select.zig` (149), `ai_threat.zig`, `ai_movement.zig` (676),
  `utility_skills.zig`, `src/skills/*` (44 files), `src/effects/*` (9 files).
- The combat brain. Lens: the 18-callback Effect interface - is every
  callback actually consumed, or is there dead contract surface; AI
  determinism + tiebreak conformance; the EvalFrame memoization + cycle
  guard; per-file self-documentation convention (`///` on skill/effect
  pub consts); integer-only math; rating-scale consistency across skills;
  whether any skill recipe duplicates machinery that belongs in
  skill_helpers; worst-case AI/eval work at the documented caps
  (performance lens).

### Part 5 - Config layer: parser, loaders, writers, file IO (~15k lines)
- `parser.zig` (1,433), `loaders.zig` (6,479), `writers.zig` (1,516),
  `file_source.zig` (1,411), `game_zip.zig` (598), `zip_reader.zig` (474),
  `zip_writer.zig` (152), `content_hash.zig` (258),
  `validation_replay.zig` (519), `session_log.zig` (904),
  `session_log_bundle.zig` (590).
- The biggest single files in the tree. Lens: OOM-panic vs error-return
  convention at every site; errdefer correctness on every error return
  (the project's own rule: every error return needs a malformed-fixture
  test - checking those tests exist); ownership contracts (borrowed vs
  duped strings, self-owned loaders); round-trip fidelity (load→write→
  load identity where it's promised); the writer/reader as inverses;
  version-gating correctness; the reconstruction-cache + bundle exactness
  promise (incl. the known custom-art dims gap - verify the documented
  impact).
- Security lens (detailed in Method): zip-slip + bomb guards in
  zip_reader/game_zip; stem/path traversal hygiene; asU32 overflow on
  hostile tokens; config integers reaching indices/sizes unbounced; panic
  sites reachable from untrusted missions/logs/saves, classified.

### Part 6 - Input layer (~10k lines)
- `input.zig` (1,651), `input_handlers.zig` (5,956),
  `input_gestures.zig` (1,467), `console.zig` (2,080),
  `dump_walker.zig` (856), `ui/keybind_edit.zig` (237).
- Lens: the hybrid precedence model + dispatch convergence (does every
  binding fire by design - the ctrl+S bug class); modifier-subset match
  correctness; the mouse-owns-the-frame + rollover edge cases TODO
  tracks; gesture lifecycle (drag cancel on focus loss - known open);
  replay-purity of everything reachable from input; the console channel's
  TTY gating; dump_walker safety invariants (never follows pointers,
  never calls methods).

### Part 7 - View + platform seam: rendering (~10k lines)
- `view.zig` (5,757), `src/raylib/*` (backend 772, textures 671, draw
  649, text 527, audio 415, input_poll 363, diagnostics 212,
  conversions), `diagnostics.zig` (491), `browser_url.zig`,
  `transient_allocator.zig`, `font_codepoints.zig` (454).
- Lens: view() purity + the per-frame arena;ViewState as the ONLY
  renderer-facing state; the letterbox/two-camera/pointer-mapping math;
  the SDF text pipeline; the emscripten allocator rule (no
  page_allocator from shared code - grepped, not assumed); the
  by-value-extern-struct aarch64 miscompile pattern (the tint shape
  rule - checked at every Color/Rectangle call site); audio cache +
  init-order; the diagnostics best-effort write discipline; the
  stripe-scope-per-tile perf note (reassessed with fresh eyes); per-frame
  allocation discipline outside the frame arena (performance lens).

### Part 8 - UI framework (~16k lines)
- `ui.zig` (206), `ui/element.zig` (1,501), `ui/state.zig` (381),
  `ui/text_input.zig` (596), `ui/tooltip.zig` (688), `ui/emit.zig`
  (889), `ui/bottom_bar.zig` (340), `ui/panels.zig` (1,897),
  `ui/screens.zig` (1,117), `ui/menus.zig` (3,893).
- Lens: the flat UiElement-list + Rect algebra coherence; the UI state
  classification (class 1 on GameState vs classes 2-4 in UiState - any
  drift); hit-testing vs drawn bounds (the text_label placeholder is a
  known item); builder consistency (emit helpers used everywhere vs
  inlined recipes); the known duplicated-recipe debt in
  buildEntityInspectPanel (verify the description still matches);
  settings screen round-trip + debounced persistence.

### Part 9 - Editor (~19k lines)
- `editor/planning.zig` (1,266), `editor/handlers.zig` (1,680),
  `editor/mission_io.zig` (847), `ui/editor_shell.zig` (2,253),
  `ui/editor_inspector.zig` (5,293), `ui/editor_pickers.zig` (2,351).
- The single largest subsystem. Lens: active-tool model + Selectable
  union (the settled design) vs implementation; planning purity (planners
  as pure click→actions functions); the editor framing + cache-needing
  inline dispatch split (is the split still principled or has it
  accreted); uuid/stem normalization in mission_io; playtest
  round-tripping; the marquee-crosses-marker UX trap (known - opinion);
  inspector field-emitter consistency + the 4.6k-line file question.

### Part 10 - Composition, platform entries, build system (~7k lines)
- `main.zig` (2,754), `session_setup.zig` (960), `native.zig` (285),
  `web.zig` (325), `build.zig` (49k bytes, ~1.3k lines),
  `build.zig.zon`, `tools/sdf_atlas_generator.zig`, `web/` dir,
  `generated_lookups.zig`, `generated_sprite_metadata.zig`,
  `generated_assets.zig` (generated - checked for generator/committed
  drift, not hand-reviewed).
- Lens: the update/view/frame wiring in main (the biggest logic file
  after the handlers - is it still composition or has it accreted
  policy); StartupMemory/teardown completeness (the web re-boot path);
  build.zig legibility at 1.3k lines (dev-mode/web-debug-runtime/
  mac/web options, the SkillId scan, test-root generation - the
  headless-exclusion contract); entry-file duplication between
  native/web; the patched-stdlib workaround documented correctly.

### Part 11 - Tests (~19k lines)
- `test_harness.zig` (211), `skill_tests.zig` (2,476),
  `handler_tests_{editor 8,764, combat 1,047, turnflow 940, gear 827,
  ai 551, autosave 436, devtools, ui_surfaces 238}`,
  `input_tests_{console 581, escape 222}`,
  `content_validation_tests.zig`, `test_ui_census.zig`,
  `font_codepoints_tests.zig`, plus inline test blocks throughout src.
- Lens: DESIGN → Testing conformance - the four bug classes actually
  covered; tier discipline (pure-fn inline vs harness drain vs contract
  vs structure); derived-expectation + awkward-values assertion patterns
  (are expectations derived or hand-copied - the census churn lesson);
  arena vs testing.allocator usage matching each loader's ownership
  contract (the arena blind-spot rules); known gaps TODO admits
  (swap_hands, new-skill drain coverage, cue-wiring assertions) -
  independently verified and quantified; test quality: do tests assert
  intended behavior or observed behavior; the round-trip reconstruction
  test + session-log round-trip coverage.

### Part 12 - Data, assets, scripts (~small code, large surface)
- `data/**` (campaigns, weapon types, settings/defaults, salvage,
  decorations, tips, themes), the balance bounds in loaders vs the
  data's actual values, LICENSE files vs the assets actually shipped,
  `.gitignore`, all nine `scripts/` (read + spot-run: are they
  self-consistent with what AGENTS claims they do; do the report
  scripts' asserts follow the write-after-each-step rule the project
  learned the hard way).
- Lens: data-file grammar conformance (headers whitelisted per format,
  Layout counts present, snake_case keys); official campaign content
  sanity (graph integrity the loader checks - and anything it doesn't);
  embedded-vs-persistent shadowing sanity.

### Part 13 - Cross-cutting sweeps (whole tree)
Only possible after everything is read:
- `unused_pub_report.sh` findings triaged one by one (dead/unused/
  test-only) with my own recommendation per symbol.
- Full-tree greps for the convention violations: `TODO`/`FIXME`/`HACK`
  markers in code; `page_allocator` outside transient_allocator in
  shared code; float usage in gameplay logic; `!replaying` gates audited
  as a set; comment conventions (`///` inside fn bodies, forward-looking
  prose); dash/punctuation check; naming-convention outliers
  (abbreviations, `idx`/`alloc` style names); line-length outliers >
  120 (the deferred style item - quantified, not fixed).
- The TODO "KNOWN DEFERRED BUGS: (none currently)" claim vs what the
  review actually found - reconciled.
- TODO's acknowledged-but-unmeasured items each get a verdict:
  confirmed-fine / worth-measuring / should-fix-now.

### Part 14 - The docs, second pass (whole docs, code-informed)
- With every line of code now read, the docs get a closing pass in the
  OPPOSITE direction from Part 1: not "are the docs internally
  consistent" but "do the docs tell the truth about the code."
- Every OPEN doc claim recorded in Parts 2-13 is resolved here (doc
  statements that could only be verified by reading the code they
  describe).
- Drift collected during the code parts gets consolidated: DESIGN
  sections that no longer match implementation, AGENTS rules the tree
  quietly violates, TODO items that are actually done or actually stale,
  Subsystem Map / Key Files entries pointing at the wrong files.
- DONE.md archiving-discipline verdict from the Part 1 skim, informed by
  everything since: is the format serving its purpose at 18.5k lines,
  and ONE improvement recommendation if any (DONE.md itself stays
  untouched - it is history, not a review target).

### Part 15 - Synthesis
- The issue register: every finding from Parts 1-14, grouped by severity,
  deduplicated, each with location + suggested disposition (fix now /
  TODO item / wontfix-with-reason).
- The highlight register: the things this codebase does unusually well,
  ranked, with pointers - the point is to know what not to break.
- Overall assessment: architecture health, doc-system health, test
  health, platform-seam health; where the 109k lines feel earned vs
  where they feel like accretion; what I'd recommend as the next three
  pieces of work purely from review findings.
- **Security-posture verdict**: the classified untrusted-input panic map
  (what a malicious mission/save/log can reach), overflow behavior in
  the builds that actually ship, and a recommendation on whether the
  fail-fast posture holds for the planned server-revalidation path or
  needs a hardened-parse tier first.
- **Performance verdict**: the measured/reasoned cost map (view rebuild,
  deepCopy/snapshots, AI at caps, per-frame allocation discipline, web
  frame-time dips), each known-unmeasured TODO item given a verdict, and
  the two or three things actually worth profiling first.
- A proposed TODO.md delta: review findings folded into the project's
  own tracking format (never applied without your sign-off; DONE.md is
  never touched by the review - it is history).

---

## Deliverable protocol

- Findings land in **PROJECTREVIEW.md**, appended part by part. Each part:
  scope recap → findings (severity, `file:line`, one-paragraph diagnosis)
  → highlights → a short part verdict.
- The issue + highlight registers accumulate in a pinned section at the
  top of PROJECTREVIEW.md (kept current as parts land, so the file is
  always a valid summary on its own).
- Nothing in the tree is modified during the review except the two review
  files themselves. No findings are fixed in passing - even one-line
  fixes are only recorded (fixing mid-review would invalidate later
  parts' ground truth and blur what the review found vs what I changed).
- Machine-check results (test.sh, builds, sweep scripts) are recorded in
  Part 13 verbatim-ish, run at the START of the review so the whole
  review describes one frozen tree state (git SHA pinned in
  PROJECTREVIEW.md's header).

## Estimated shape

15 parts, roughly ordered small→large per session. Parts 5, 9, 11 are the
heavyweight reads (loaders/editor/tests, ~19k lines each when their test
file is counted in). Total coverage: every tracked file in the repository
touched by at least one part; the docs read twice (before the code, then
code-informed); DONE.md the only skimmed file, and only for archiving
discipline.
