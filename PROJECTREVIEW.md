# Ziglop - Project Review

Review of the full repository per REVIEWPLAN.md. Nothing in the tree is
modified during the review except this file (and REVIEWPLAN.md itself).
Each part lands as a section below, in order.

**Frozen tree state:** git `0f41942e4c91c606a57f39819648f530a3d33733`,
clean working tree (only REVIEWPLAN.md untracked). Every finding below
describes this SHA.

Severity scale: **Critical** (player-visible bug / data loss / broken
invariant) · **Major** (real debt or drift) · **Minor** (local polish,
consistency) · **Nit** (taste) · **Highlight** (well-made; worth
protecting and imitating).

---

## Pinned summary (kept current as parts land)

| Part | Scope | Status | Notable |
|---|---|---|---|
| 0 | Machine checks | done | All green except `zig fmt --check` (10 files) |
| 1 | Docs, first pass | done | 1 Major (doc drift: saturation), 4 Minor, 2 Nit; 5 Highlights; TODO-accuracy spot-checks all passed |
| 2 | Core kernel (types/events/state/deep_copy/functions/tween) | done | 3 Minor (1 real code bug: `write_fn(undefined)`), 2 Nit, 5 Highlights; integer-only + purity discipline hold; 6 instances of a doc-comment-orphan drift class |
| 3 | Event pipeline + handlers | done | 2 Minor (hub move_player unvalidated at replay seam; doc-drift count now 11), 2 Nit, 5 Highlights; purity gates verified at every site; force-unwrap question resolved |
| 4 | Skills, effects, AI (44 skills + 9 effects + 5 AI files) | done | 3 Minor (1 armed landmine in that_which_lingers; rating-doc drift in 3 skills; template doc-doubling ×6), 5 Highlights; 18/18 Effect callbacks consumed; integer-only holds; AI worst-case cost trivial at caps |
| 5 | Config layer (parser/loaders/writers/file_source/zip×3/session_log×2/content_hash/validation_replay) | done | 3 Minor (FileSource path-normalization gap + bundle size cap - both server-seam hardening; doc-drift ~17), 1 Nit, 6 Highlights; zip-slip/bomb defenses best-in-class; boundedU32 coverage verified at every gear-stat site |
| 6 | Input layer (input/input_handlers/input_gestures/console/dump_walker/keybind_edit) | done | 1 Minor (InputState doc claims the WRONG state home - semantically misleading drift #18), 1 Nit, 6 Highlights; vestigial-`!replaying` TODO item RESOLVED (gates confirmed dead - keep + document); dispatch convergence + precedence verified with shipped-bug tests |
| 7 | View + raylib platform seam (view.zig + 8 raylib files + diagnostics/browser_url/transient_allocator/font_codepoints) | done | 1 Minor (world-layer missing art draws NOTHING, not the promised magenta - doc/impl drift), 1 Nit, 6 Highlights; aarch64 tint rule CLEAN; allocator rule CLEAN; camera math verified; perf items reasoned |
| 8 | UI framework (element/state/text_input/tooltip/emit/bottom_bar/panels/screens/menus + facade) | done | 0 Minor, 1 Nit, 6 Highlights; UI state classification holds under machine verification (both directions); all 3 known gaps confirmed as accurately tracked |
| 9 | Editor (planning/handlers/mission_io + 3 editor UI files) | done | 1 Minor (mission-zip import lacks the game import's bomb caps - Part 5 open item RESOLVED as a finding), 1 Nit, 6 Highlights; planner purity + placement invariants + selection consistency all verify; marquee UX opinion formed |
| 10 | Composition, entries, build (main/session_setup/native/web/build.zig/tools + generated files) | done | 0 findings; main.zig verified as composition-with-rationale (no accretion); teardown + headless-exclusion contracts hold; build.zig is clean generator structure |
| 11 | Test suite (harness + 14 tier files + the inline test mass read across Parts 2-10) | done | 0 new findings; all TODO coverage admissions verified PRECISE (swap_hands=0, tier cue assertions=0, skill drain=adrenaline-only); census helper hoist happening; assertion patterns verified with honest caveats |
| 12 | Data, assets, scripts | done | 0 findings; all 14 shipped Layout files use the counted grammar; gear stats at-or-under every bound (several deliberately AT max); versions consistent; scripts verified (Part 0 + harness smoke) |
| 13 | Cross-cutting sweeps | done | 0 new findings; TODO/FIXME markers ZERO violations; naming/float/replay-gate rules hold tree-wide; line-length quantified (785/120, 109/160) for TODO's style decision; "no deferred bugs" claim reconciled (was honest; review adds 6) |
| 14 | Docs, second pass (code-informed) | done | 0 new findings; exactly 2 DESIGN drifts found across all subsystem verification (M-1.1 + m-7.1); TODO accuracy confirmed; DONE verdict: generated header index is the one improvement |
| 15 | Synthesis | done | Issue register (0C/1M/13m/11n deduplicated) + top-12 highlight register + security verdict (safe-mode-build recommendation is the headline) + perf verdict (3 profiling candidates) + recommended next work + proposed TODO delta |

**FINAL: 0 Critical · 1 Major · 13 Minor (deduplicated; 18 as-counted) · 11 Nit · 67 Highlights. Review complete - all 15 parts delivered.**

---

## Part 0 - Machine checks (the frozen state)

Run at review start so every later part describes one tree state.

| Check | Result |
|---|---|
| `scripts/test.sh` | **PASS (exit 0)** |
| `zig build` (native) | OK |
| `scripts/web.sh` (web compile, patched stdlib) | OK |
| Web **runtime** (browser, static serve) | **RUNS**: canvas + WebGL2 alive, ~61fps rAF loop, non-black pixel readback, emscripten Module fully wired |
| Node headless web probe (`node zig-out/web/ziglop.js`) | Boots the wasm, fails only at the canvas/DOM seam - expected headless; early-boot path intact |
| `scripts/dash_sweep.sh --check` | CLEAN |
| `scripts/doc_symbol_check.sh` | CLEAN - 248 doc symbol paths all resolve |
| `scripts/unused_pub_report.sh` | 589 pub declarations: **0 dead, 0 unused**, 3 test-only (documented convention) |
| Report regeneration (art / sound / gradient) + diff | **Zero drift** - all three committed/working reports regenerate byte-identical |
| `zig fmt --check src/ build.zig tools/` | **FAILS - 10 files** (see finding M-0.1) |

Findings from the checks themselves:

- **M-0.1 (Minor) - `zig fmt --check` fails on 10 files; no fmt gate exists
  anywhere.** `src/handlers/meta.zig`, `src/ui/editor_inspector.zig`,
  `src/input_handlers.zig`, `src/art_report.zig`, `src/file_source.zig`,
  `src/view.zig`, `src/loaders.zig`, `src/content_validation_tests.zig`,
  `src/game_zip.zig`, `build.zig`. The divergences I sampled are cosmetic
  (zig 0.16 fmt's comment-attachment in nested struct literals; one
  alignment in build.zig) - nothing semantic. The notable part: AGENTS.md
  prescribes dash sweeps, doc-symbol checks, and unused-pub reports as
  commit checkpoints, but `zig fmt` appears in no doc at all, so the tree
  has silently accumulated fmt drift. Disposition suggestion: either add
  `zig fmt --check` to the commit checkpoint (it is byte-stable and the
  fix is one command), or record a deliberate "fmt is not a gate" decision
  in AGENTS so the drift is policy, not accident.
- **H-0.1 (Highlight) - the machine-walked-truth discipline actually
  holds.** Three independently regenerable reports regenerate
  byte-identical to the tree; the doc-symbol checker is clean across 248
  paths; the unused-pub report shows zero dead API surface out of 589
  declarations. For a 108k-line codebase developed over 764 commits
  largely by agents, this is exceptional - most trees this size carry
  dozens of dead symbols and stale docs. The "generate it instead of
  curating it" rule (AGENTS → Documentation) is visibly enforced, not
  aspirational.
- **H-0.2 (Highlight) - "compiles ≠ runs" is taken seriously and
  verified.** The web build was runtime-verified in a browser at the
  frozen SHA (not just compiled): rendering loop alive, non-black output.
  The project's own history (136-commit web black screen, mac miscompile)
  taught this lesson and the docs encode it; the review confirms the
  current state passes it.

---

## Part 1 - The docs, first pass

**Scope:** AGENTS.md (822), DESIGN.md (6,301), TODO.md (999), README.md
(81), the three derived reports (checked for derivation, proofread
lightly), DONE.md (18,498 - skimmed for archiving discipline only, per
plan; it is history and is never modified by this review).

### Internal consistency + lifecycle conformance

The four-file lifecycle (open question → TODO; settles → DESIGN; completes
→ DONE + one-liner) is genuinely practiced, not just documented:

- TODO.md is scannable as designed: every `[x]` item I read is a one-liner
  or short pointer into DONE.md; open questions sit inline with the tasks
  that need them; rejected alternatives are named (the coverage-matrix
  rejection, the transactional-recording rejection) rather than left
  implicit.
- AGENTS → DESIGN pointer discipline held up across a full read of both
  files: I found no design prose restated in AGENTS and no working-rule
  prose restated in DESIGN. The one-directional split (AGENTS = how to
  work, DESIGN = what is settled and why) is real.
- DONE.md's header states the archival contract ("entries are historical,
  not maintained after archiving") - which is what lets DESIGN be edited
  freely without DONE rot.

Findings:

- **M-1.1 (Major, doc drift) - DESIGN → Clones claims a saturation guard
  that is not implemented.** The section's "Saturation" paragraph reads
  "Material wallet ADDS clamp at u32 max, never wrap (silent wraparound
  would destroy wealth) - see Post-game Rewards & Cosmetics → Overflow
  guard", present tense, no deferred marker. Code check at this SHA:
  `types.Materials.add` (types.zig:2334) is five plain `+=` lines - no
  clamp - and the actual add sites (`harvest_clones` at
  handlers/player.zig:296, salvage at :360) call it directly. TODO →
  Post-game correctly lists "saturating material adds" as an open task,
  and the Post-game DESIGN section is clearly framed as
  settled-design-implementation-deferred - but the **Clones** section
  cites the guard as if it exists. A reader of DESIGN → Clones alone
  would believe overflow is impossible. Consequences beyond the doc lie:
  in Debug/ReleaseSafe an overflow panics (acceptable fail-fast); in a
  ReleaseFast build it wraps silently - exactly the failure the doc says
  never happens (a crafted farm mission is the realistic trigger; feeds
  the security lens, Part 5/15). Disposition: one-line fix in DESIGN →
  Clones ("design rule; lands with TODO → Post-game rewards") plus the
  TODO task - or, better, land the three-line saturating `add` since the
  TODO notes it is "small + independent of the rest; could land early".
- **m-1.2 (Minor) - the three sibling reports are treated inconsistently
  by git.** `art_report.md` and `gradient_report.md` are tracked;
  `sound_report.md` is in `.gitignore` and has never been tracked
  (`git log --all` empty). All three are machine-derived shopping lists
  of the same kind, regenerate cleanly, and churn the same way (when
  assets land). If the sound-report ignore is deliberate (e.g. so the
  sound designer's local regeneration never pollutes commits), the
  asymmetry with art_report deserves a comment in .gitignore saying so;
  otherwise track all three or ignore all three.
- **m-1.3 (Minor) - DESIGN.md is 6,301 lines / 405 KB in one file with no
  index.** The Subsystem Map in AGENTS points into it by section name,
  which works, but there is no table of contents and several sections are
  400+ lines; finding a specific settled decision inside (say, the
  outline-stripe band-width rule) requires grep. A machine-generated
  `##`-header index at the top (one line per section, derivable - the
  project's own generated-lookups pattern) would cost ~30 lines and make
  the file navigable without search. Not urgent; the file is otherwise
  well-organized with consistent section discipline.
- **m-1.4 (Minor) - AGENTS.md at 822 lines is at the edge of its
  "read at the start of a session" job.** The working-rule content
  genuinely belongs there, but several long passages are historical
  case-study prose (the sweep-script lessons block, the ButtonPayload
  migration story, the ai_options migration aftermath - each a multi-
  paragraph narrative of past sessions). DONE.md is the designated home
  for "the why we did X history"; AGENTS could carry the one-line rule
  with a DONE pointer and stay perhaps 20% shorter. Borderline - the
  case studies do teach the rule's rationale - but the file now takes a
  meaningful fraction of a session-start context budget, and every
  future subsystem adds more.
- **n-1.5 (Nit) - `.gitignore` comments are interleaved after their
  patterns with several stale references, and one line is truncated
  mid-word ("# Test scratch namespace (test_harnesss").** Cosmetic, but
  the file is the first thing a new contributor reads; a two-minute
  rewrite would group pattern+comment pairs coherently.
- **n-1.6 (Nit) - README's "in early stages of development" undersells
  the current state** (end-to-end core loop natively + on web, 44 skills,
  a working mission editor, replay + crash-dump machinery). Harmless for
  a pre-rename private repo; will want a rewrite at the demo milestone
  alongside the planned taplop rename.

### TODO accuracy against the tree (spot-checks, all passed)

Every TODO/AGENTS claim I could verify cheaply was true - notable, since
doc accuracy is usually where long-lived agent-written projects rot:

- "gear_sprites is emitted empty" - confirmed (`view.zig:1975,2103`,
  `.gear_sprites = &.{}`).
- "interact_with_npc is a `{}` stub" - confirmed
  (handlers/player_input.zig:1126).
- `scripts/test.sh` cleans `crashes/` before/after a passing run -
  confirmed (lines 31, 88).
- Generated files (`generated_assets.zig`,
  `generated_sprite_metadata.zig`, `src/generated_lookups.zig`,
  `src/generated_test_root.zig`) are gitignored - confirmed.
- "handler_tests_editor.zig is the tree's biggest (8.8k lines)" -
  confirmed (8,764; largest file in src/).
- Every `src/*.zig` path named in AGENTS → Key Files exists - confirmed
  (zero missing).
- Line counts quoted in TODO/AGENTS (109k tree, 822/6,301/999/18,498
  docs, 44 skills, 892 tests, 764 commits) - all confirmed at this SHA.

Claims that need code reads are recorded below as OPEN and resolve in
their parts.

### DONE.md archiving-discipline skim

- 267 `##` entries + 264 `###` sub-entries. Two archival shapes coexist:
  ~10 early mega-sections (`## Foundation (done)` 1,582 lines, `## Error
  Handling` 1,206, `## Level editor UI` 2,308 - the largest) followed by
  a long tail of flat per-slice `##` entries. Newest-at-bottom within
  sections works. Entry sizes: median 37 lines, p90 65 - slices are
  consistently sized; nothing bloated except the legacy mega-sections.
- **The collapse rule (TODO `[x]` → one-liner + DONE entry in the same
  commit) is followed**: recent `[x]` items in TODO are all collapsed
  pointers, and the most recent DONE entries match the most recent
  commits one-for-one.
- Improvement candidate (ONE, per plan): a machine-generated `##`-header
  index at the top. 267 headers is past scroll-navigation; today finding
  "which DONE entry explains X" means grep (which works, but an index
  generated from the headers costs nothing and cannot drift - the
  project's own pattern). The legacy mega-sections could be flattened
  into per-slice headers for consistency, but that is cosmetic churn on
  a history file - not recommended by this review. TODO already tracks
  the "divided history format someday" question; nothing urgent.

### Highlights

- **H-1.1 - The doc lifecycle works in practice, not just on paper.**
  Reading all four docs in full found: no fact restated across files, no
  stale symbols (machine-checked), no `[x]` items carrying stale prose,
  and TODO claims that survived spot-checks 100%. I have rarely seen a
  project where documentation and code stay this honest with each other,
  human- or agent-written.
- **H-1.2 - DESIGN.md's "track the cost, not just the decision" style.**
  Settled decisions carry their limitations inline at the decision site:
  the InputBindings full-replace shadowing caveat, the undo-then-failed-
  load redo-loss edge case, the snapshot ring's post-branch holes, the
  occlusion-inset adjacent-entity approximation, the keep_range
  multi-hostile limitation. Each is a known cost recorded where the next
  session will meet it, rather than discovered as a surprise. This is
  the single best feature of the design prose and worth preserving as a
  convention.
- **H-1.3 - DESIGN → Testing is a real test philosophy, not coverage
  theater.** The four bug classes, contract-over-mechanics assertion
  rule, derived expectations, exhaustiveness-over-pinned-windows, the
  deletion policy ("a suite that only grows accretes churn"), and the
  reasoned rejection of a coverage matrix - this section is why the suite
  teaches rather than merely counts. (Part 11 verifies the tests match
  the philosophy.)
- **H-1.4 - Honest uncertainty.** TODO distinguishes measured vs
  accepted-not-measured items, marks owner-undecided items as such, and
  keeps genuinely open design questions visibly open instead of
  papering over them. The docs never pretend a decision is more settled
  than it is - with the one exception of M-1.1.
- **H-1.5 - README is a working quickstart** - build/run/test, dev mode
  semantics, the scratch-data-dir trick, the patched-stdlib web workflow
  with its expiry condition. A stranger can go from clone to running
  game from the README alone.

### OPEN items (resolve in later parts / Part 14)

- "KNOWN DEFERRED BUGS: (none currently)" - reconciled against review
  findings in Part 13.
- The perf claims that are "accepted-not-measured" (stripe-scope flushes,
  web frame-time dips, mouse-owns-the-frame) - reasoned verdicts in
  Parts 7/13.
- DESIGN claims only code can verify (purity gates, `!replaying`
  conventions, arena ownership, balance bounds coverage, zip-safety
  rules) - verified in their parts; drift found there lands in Part 14's
  consolidation.
- AGENTS "822 lines is still loadable" is a user-taste question
  (m-1.4), not a code question - flagged for your judgment.

### Part verdict

The documentation system is the strongest part of this project so far -
it is doing exactly what it was designed to do, with machine-checked
honesty, and it is the reason a review like this is even feasible. The
one real defect found (M-1.1, the saturation doc-lie) is exactly the
drift class the project's own lifecycle rules exist to prevent - a
settled-design statement leaked into a present-tense implementation
claim. Four minor structural observations (report tracking asymmetry,
DESIGN size/index, AGENTS size, gitignore hygiene) and two nits round
out the pass. No Critical or code-level findings - as expected: this
part read prose, and the prose is unusually well-kept.

---

## Part 2 - Core kernel: types, events, state (~11.4k lines)

**Scope:** `types.zig` (3,993), `events.zig` (1,624), `state.zig` (3,581),
`functions.zig` (891), `deep_copy.zig` (242), `tween.zig` (38) - read in
full. The game's spine: GameState/History, undo/redo/replay timeline,
snapshot/checkpoint rings, the reconstruction cache, replay legality
validation, the entity model + getEffective* math, A*, and the
deep-copy/equal machinery behind replay verification.

### Invariant verification (the lenses, applied)

- **Integer-only gameplay: HOLDS in the kernel.** All gameplay state is
  i32/u32; f32 appears only where DESIGN allows it (view types:
  `HealthBarDrawable.fill_fraction`, `ViewState.world_scale`,
  `outline_stripe_phase`; the input seam: `CameraPanAnchor`,
  `held_modifiers`-adjacent pointer math; `tween.zig`, rendering-only).
  `functions.zig` is 100% integer. `deepCopy` passes floats through but
  no event payload carries one (verified against every union in
  events.zig) - which is what makes `deepEqual`'s exact `==` sound.
- **The GameState/SessionState split: HOLDS without exception.** Every
  SessionState field carries a doc naming its side of the line and why
  ("off the undoable GameState → replay-safe by construction"); class-1
  surface state lives on `GameState.ui_surfaces` behind events, classes
  2-4 on SessionState. I looked for a violation and found none in 11k
  lines. `transitionScreen` closing class-1 surfaces handler-side while
  the live loop resets classes 2-4 wholesale matches DESIGN exactly.
- **Ring buffers:** the FIFO property and the post-branch null holes are
  exactly as TODO documents them ("Harmless, never wrong... deliberately
  left as-is"). Confirmed by reading `takeSnapshot`/`setCheckpoint`/
  `discardFutureTimeline`: a nulled slot is only reused when the marching
  ring index reaches it, so capacity is briefly under-filled after an
  undo branch. Verdict: agree with the recorded decision - the quick fix
  would break oldest-eviction; revisit only with measured undo latency.
- **The ~26 `current.level.?` force-unwraps** live in the handlers
  (Part 3's read); the state-side validation code uses `orelse return`
  (correct there - validation runs against crafted logs where null means
  "no check possible"). Opinion deferred to Part 3 as planned.
- **Naming/style:** verbose naming held throughout (`entity_index` not
  `idx`, `allocator` not `alloc`); multiline signatures on the long fns;
  pub surface is lean (state.zig's pub fns all have cross-file
  consumers; unused_pub_report already confirmed 0 unused tree-wide).

### Findings

- **m-2.1 (Minor, real code bug) - `markWriteDirty`'s overflow fallback
  is UB, not a fail-fast.** state.zig:642: when the 4-slot
  `pending_writes` array is full, the fallback is `write_fn(undefined)` -
  calling `writeSettingsToFile` on an **undefined** `GameStateHistory`,
  i.e. dereferencing garbage. The comment correctly says reaching it is
  "a real bug; max_pending_writes should cover all tags" - but the
  designed response to a real bug in this codebase is `@panic`, and this
  path instead silently does something far worse than the bug it guards
  against (an undefined-history write could corrupt the settings file
  with garbage before crashing). One-line fix: `@panic("pending_writes
  overflow - max_pending_writes must cover all write tags")`.
- **m-2.2 (Minor, systematic doc-comment drift) - six instances of
  orphaned/duplicated/stale `///` text in the kernel, a class no tool
  checks.** The doc-symbol checker validates backticked paths in the
  .md files only; comment text is unchecked, and refactors leave it
  behind. Instances (all in types.zig / events.zig / state.zig):
  1. types.zig ~line 370: a stale orphan doc block above
     `skillTypeBaseSound` describing a removed action-sound mapping and
     naming `button_click_up`/`button_click_down` - SoundIds that no
     longer exist (renamed `button_base_*`).
  2. types.zig, `MissionCompleteInfo`: its doc block is doubled - the
     old two-line version fused ahead of the current one.
  3. types.zig, above `StackSprite`: a truncated fragment of the old
     `OcclusionInsetDrawable` doc, cut mid-sentence ("...the"), left
     behind when the type gained the stack model.
  4. events.zig, `player_place_editor_decoration`: its comment block is
     verbatim-doubled (nine lines repeated).
  5. events.zig, `player_paint_editor_tile`: the comment ends "Erase
     (right-click) and drag-painting are deferred; each lands as its own
     gesture" - both have since LANDED (`player_delete_editor_at` in the
     same file; drag-paint per DESIGN). A reader today is told the
     feature doesn't exist.
  6. state.zig, `validatePlayerAction`: three doc blocks fused into one
     - its own doc plus the orphaned docs of
     `validateEditorLevelMetadataCommit` and `validateInspectorEntityEdit`
     (which now have no docs of their own).
  Not individually serious, but systematic: the project's comment
  discipline is otherwise exceptional, and these are exactly where a
  future reader trusts the prose. Disposition suggestion: fix the six in
  one pass; longer-term, this is the comment-side analog of the
  doc-symbol checker's MOVED class - worth a line in AGENTS ("when
  moving/renaming a fn, its /// moves with it") rather than a new tool.
- **m-2.3 (Minor, type shape + comment-rule violation) -
  `PlayerData.discovered_hubs: []const Hub`.** The discovered set is
  semantically a set of hub NAMES, but the field stores full `Hub`
  structs (tiles, player Entity, npcs, decorations, mission_exits) - and
  the save format serializes only `name` from each (parser.zig:
  `save_discovered_hubs_keys = {"name"}`). The runtime consumer hasn't
  landed (campaign-editor slice 2, TODO); when it does, this shape forces
  either cloning whole hubs on discovery or re-typing the field - and
  every snapshot then deep-copies full hub structs per discovered hub.
  Re-typing to `[]const []const u8` (names) before slice 2 lands is
  nearly free now and expensive later. The field also carries the two
  forward-looking comments I found in the whole kernel ("// will also be
  used to identify completed missions - maybe per campaign also?" and
  "// change to be per campaign") - TODO-prose in code, violating
  AGENTS' own comment rule; the only two instances found in 11k lines,
  which is itself a testament to how well the rule is kept.
- **n-2.4 (Nit) - `validateSkillTarget(level, player, skill_id, target)`
  takes and immediately discards two parameters** (`_ = level; _ =
  player;`) - a leftover signature from before the check moved to
  `skillTargetLegal`.
- **n-2.5 (Nit) - `SessionState.save_files_last_scan_us` is declared ~40
  lines away from the `save_files` field it timestamps**, stranded among
  the validation-replay fields by an incremental insert. Field-grouping
  drift, cosmetic.

**Security-lens notes (feeding Parts 5/15, not standalone findings):**
`getEffectiveMaxHealth` adds an UNBOUNDED authorable `max_health` to four
bounded bonuses - a crafted mission with max_health near u32 max
overflows the add (Debug/ReleaseSafe: panic; ReleaseFast: wrap), the
same family as Part 1's saturation gap. `applyModifier`'s
`@as(i32, @intCast(base))` panics for base > i32max, but the two-gate
replay system makes that unreachable from crafted logs (attack is
machinery, never seeded at an idle point; legal player paths cap damage
around ~130). The legality machinery itself held up under adversarial
reading - see the highlight below.

### Highlights

- **H-2.1 - The two-gate replay-legality system is genuinely
  anti-cheat-grade design.** The structural whitelist
  (`isPlayerAction`: the PlayerInputEvent TYPE is the whitelist, so it
  cannot drift from the push side) plus `validatePlayerAction`'s
  per-arm context checks (screen, palette/tool/index ranges, the
  surface-supply gate mirroring what the live pointer path can click,
  skill-on-bar/off-cooldown, full-BFS move legality) plus
  `verifyReplayMatch`'s natural-stack child verification - a crafted log
  must survive all three. I attempted to find a seeding path around it
  and could not: machinery events can't be seeded, orchestrator payloads
  are range-checked against live state, and side effects are
  replay-gated. The exhaustive switches mean every new player action is
  a compile error until its legality arm is written - the design
  compounds instead of accreting.
- **H-2.2 - `deep_copy.zig`: 242 lines carrying the determinism
  guarantee, with the type system as its test.** `deepCopy`/`deepEqual`/
  `firstDiffField` compile-ERROR on unsupported shapes (untagged unions,
  non-slice pointers) - so the moment anyone adds a raw pointer or
  untagged union to GameState or Event, the build breaks. The
  reflection tracks new fields automatically, and the tests cover the
  tricky cases (union payload recursion for firstDiffField, slice
  length mismatch). This is the quiet load-bearing wall of the whole
  replay architecture.
- **H-2.3 - Pathfinding carries its bug history as executable
  regression tests.** The admissibility test embeds the exact
  fuzz-counterexample tile map that defeated the old Manhattan heuristic
  (commented with the map + the 5-step vs 6-step paths); the
  same-row-chase and diagonal-chase tests pin the straightness
  tiebreak's intent, not its mechanics. Someone hitting a future
  heuristic regression gets a 30-second diagnosis. (`applySignedDelta`
  and `nearestTileAlongDirection` get the same treatment - boundary
  cases, awkward values, behind-the-origin rejection.)
- **H-2.4 - `validatePlayerAction`'s panics all route through
  `rejectReplay`** - one seam where normal mode panics and checking mode
  records, so the future server-side revalidation (DESIGN → Custom
  Missions → Auth & the server seam) gets the identical legality logic
  with a non-crashing policy for free. The revalidate path is already
  the in-process miniature of the server check. Foresight that costs
  nothing today and is exactly right later.
- **H-2.5 - The `drainPendingSounds` no-memset drain, WITH its
  regression test.** The comment explains the
  `clearRetainingCapacity`-memsets-undefined trap, the code resets
  `.items.len` directly, and a dedicated test ("drained slice stays
  valid after clear") pins it. Most codebases would ship that as a
  heisenbug; this one turned the stdlib trap into a documented,
  tested invariant. The same pattern repeats for
  `drainPendingAnims`.

### OPEN items (resolve in later parts)

- The ~26 `current.level.?` force-unwraps - opinion in Part 3.
- `file_source` path normalization (traversal hygiene for
  `save_path`/mission paths from crafted logs) - Part 5.
- Handler-side use of `Materials.add` (M-1.1's blast radius: pickup
  accumulation + salvage + harvest) - Part 3.
- Binding-combination edge cases (`sameCombo`, `isSuppressed`
  first-listed-wins) get exercised in Part 6's input read.

### Part verdict

The kernel is the strongest code I have read in this project so far -
and stronger than most game kernels I've read anywhere. The invariant
architecture (purity, the state split, the two-gate legality, the
compile-error-on-unsupported-shape deep copy) is not just present but
enforced by the type system at every seam where enforcement is possible,
and the doc comments explain WHY with DESIGN pointers at a density I
could fault only in the six drifted instances. The real defects found
are one genuine but tiny latent bug (m-2.1, one line), one type-shape
debt best fixed before its consumer lands (m-2.3), and a comment-hygiene
class (m-2.2) that matters precisely because the rest of the comments
are good enough to be trusted. No Critical findings; nothing found that
threatens the replay/determinism guarantees.

---

## Part 3 - Event pipeline + handlers (~5.3k lines)

**Scope:** `event_handlers.zig` (144), `event_push.zig` (75),
`handlers/meta.zig` (870), `handlers/level.zig` (1,563),
`handlers/player.zig` (475), `handlers/player_input.zig` (1,366),
`handlers/shared.zig` (257), `crash_dump.zig` (333), `combat_log.zig`
(215) - read in full. The update half of the Elm loop: dispatch, the
category handlers, the player-input orchestrators, and the crash-dump /
combat-log satellites.

### Invariant verification

- **Purity + `!replaying` gating: AIRTIGHT in practice.** I checked every
  side-effect site across all ~5.3k handler lines - every
  `queueSound`/`queueCue`/`queueAnim`, every file write, the browser
  download, the validation-replay write, the backup copy - and every one
  is gated on `!history.replaying` (or lives inside a wholly live-only
  orchestrator like `player_revalidate_mission`, whose entire body
  returns early on replay). I found zero ungated sites and zero pure
  transforms that touch SessionState. The project's central invariant is
  not aspirational - it is enforced line by line, and after this read I
  trust it.
- **Orchestrator convention:** every input-pushable event is a thin
  orchestrator; the machinery verbs live in the other unions; the
  `pushPlayerAction` compile-time gate makes it impossible for the input
  layer to push machinery directly. Verified across all ~100
  PlayerInputEvent arms: they push children, mutate UI-surface state via
  events, or (rarely, e.g. `swap_hands`, `dismiss_mission_complete`) do
  small inline transforms that are pure GameState writes.
- **LIFO push-order reasoning is documented at every multi-event push.**
  The hardest class of bug in this architecture (stack-order mistakes)
  is defended by inline comments spelling out the pop order at each
  site: the enemy move-then-attack triple, the knockback
  move-before-collision, the adrenaline resets-before-attacks, the
  end_level exit-event block (sync → harvest → save → write), the
  backup_autosave-after-start_hub ordering trap, the select-all
  tool-switch-last. Each reads as a designed decision with its failure
  mode named.
- **The `current.level.?` force-unwraps (TODO's UNDECIDED item) - verdict:
  keep (option A), with one caveat that belongs to the security verdict.**
  The invariant is structural: machinery events are only ever pushed by
  handlers already operating on a level, the stack is cleared on every
  screen transition, and crafted logs cannot seed machinery at an idle
  point (Part 2's gates). So the ~26 unwraps are genuine fail-fast
  assertions of a real invariant, and option B's silent return would
  hide exactly the bug class the unwraps exist to catch. THE CAVEAT: in
  a ReleaseFast build, `.?` on null and unchecked slice indexing are
  safety-checked UB - the "fail-fast" property only exists in Debug and
  ReleaseSafe. The actionable recommendation is not to touch the
  unwraps but to RECORD that the future server-revalidation build must
  be a safe-mode build (ReleaseSafe minimum), so every panic-based
  validation path stays a panic. This goes in the Part 15
  security-posture verdict.
- **Vestigial-gate TODO item (input-layer `!replaying` gates):** the
  input-layer sites live in input_handlers.zig - confirmed in Part 6,
  not here.

### Findings

- **m-3.1 (Minor, security-lens) - hub `move_player` has NO legality
  validation at the replay seam.** Level movement is rigorously
  validated (`isPlayerMoveLegal` full BFS against live state, Part 2);
  hub movement is in `validatePlayerAction`'s "no payload to validate"
  group and the handler (`player_input.zig`'s `.move_player` arm) writes
  `hub.player.position = move.destination` unconditionally. A crafted
  log can teleport the hub player to any tile. Impact today is low - hub
  position gates nothing except landing on a mission exit (which starts
  a mission, itself a legal action from that hub) - but it is a
  consistency gap in the anti-cheat surface and the fix is the same
  shape as the level arm (BFS over `hub_tiles`, or at minimum
  tile-membership + adjacency, in a bool helper +
  `validatePlayerAction` arm). Worth landing before the server seam.
- **m-3.2 (Minor) - the doc-comment drift class grows to 11 instances,
  now including a `//!` file header and matching stale prose in
  .gitignore.** New in this part: (8) `itemFitsGearSlot` (player.zig)
  has its doc line doubled (old + new phrasing fused); (9)
  `player_move_editor_selection` (player_input.zig) carries both the old
  and new versions of its comment block; (10)
  `player_set_editor_entity_sprite`'s comment still says "the sprite id
  is a plain text field in v1 - the centered sprite picker replaces it
  later" - the picker LANDED (per DESIGN + the same file's picker-close
  pushes); (11) crash_dump.zig's `//!` header says the panic handler
  "dumps the live event_history to
  `crashes/crash_YYYYMMDD_HHMMSS.txt`" - it writes a session-log BUNDLE
  directory, and the body + tests say so; `.gitignore` carries the same
  stale ".txt" phrasing. Same disposition as m-2.2: one cleanup pass
  (this file header one is the most misleading - it describes the
  artifact's format wrong).
- **n-3.3 (Nit) - `getPlayerEntity` ignores its `entity_index` parameter
  in the hub branch** (returns `hub.player` regardless). Every caller
  passes 0 today, but the signature promises per-entity addressing that
  the hub branch does not deliver - a future non-zero caller would
  silently mutate the player. Either drop the parameter (rename to
  `getPlayerEntityZero`) or assert it is 0 in the hub branch.
- **n-3.4 (Nit) - the build-tile-set / build-occupied-set block is
  duplicated four times** (knockback + retreat arms in level.zig,
  `shortestPath` + `reachableTiles` in functions.zig), ~15 lines each
  with slightly different exclusion rules (mover vs defender vs
  dead-entity handling). A shared helper parameterized on the exclusion
  would collapse it; the differences are small enough that the drift
  risk is real but the current copies are individually correct.

**Security-lens notes (Part 15):** `equip_item`/`learn_skill`/
`salvage_item` index `inventory.slots[...]` directly (TODO already
tracks the convention question) and `getPlayerEntity`/`getLevelEntity`
do no bounds check - all safe today because the orchestrator gates
bounds-check every index before seeding and machinery is never seeded;
in ReleaseFast the same inputs would be UB, which reinforces the
safe-mode-build recommendation above. `Materials.add` confirmed as the
unsaturated add at both call sites (`harvest_clones`, `salvage_item`) -
M-1.1's blast radius is exactly the two sites + the pickup accumulator
(level.zig's `pickup_items`), all in this part's files.

### Highlights

- **H-3.1 - The purity discipline is real at the line level.** ~5.3k
  lines of handler code, every observable side effect gated, zero
  exceptions found by full reading (not sampling). This is the
  invariant the entire replay/undo architecture stands on, and it is
  maintained the hard way - at every call site - rather than by a
  wrapper or convention that could be forgotten.
- **H-3.2 - `end_level` is the best function in the codebase so far.**
  One handler cleanly owning three exit regimes (campaign, editor
  playtest, validation - the last with and without a live editor for
  cross-session replay), each with the inline-teardown-vs-
  transitionScreen-stack-clearing trap navigated and explained at the
  site, plus the clone-harvest choreography with its LIFO array order
  spelled out. It is the densest concentration of the project's
  hardest invariants in one place, and it reads clearly.
- **H-3.3 - Every multi-event push carries its pop-order reasoning
  inline.** The LIFO stack is this architecture's sharpest edge, and
  the codebase treats it accordingly: no push site relies on the reader
  mentally simulating the stack. This is the difference between an
  event-stack design that decays and one that survives 764 commits of
  agent-driven change.
- **H-3.4 - crash_dump as a reproducible artifact.** A panic dumps a
  full session-log BUNDLE (log + embedded content bytes, hash-verified
  on load), so a crash report replays exactly on any machine. The
  best-effort discipline (every failure swallowed, output on the
  transient allocator, never the possibly-corrupt game arenas) is
  right, and the detail of moving the success print OUT of `dump` so
  passing tests don't print crash-like output shows the level of care.
- **H-3.5 - combat_log.zig: small, pure, and decisive.** The tier
  classification is an exhaustive switch with a reasoned, documented
  `.damage = .none` call (the attack entry already represents the hit;
  revisit note included), and the tests cover the whitelist, the span
  clamp, and the empty case. A projection done exactly right at 215
  lines.

### OPEN items resolved / carried

- Force-unwrap question: RESOLVED (keep, + safe-mode-build
  recommendation carried to Part 15).
- M-1.1 blast radius: confirmed - three unsaturated add sites
  (`harvest_clones` handler, `salvage_item` handler, the
  `pickup_items` accumulator).
- The vestigial input-layer `!replaying` gates: Part 6.
- `start_hub`'s hardcoded `data/campaigns/{campaign}/...` path shape vs
  the persistent-dir `campaigns/...` convention in DESIGN's
  custom-asset section - noted for Part 5's file_source read (custom
  campaigns may need a path decision when the campaign editor lands).

### Part verdict

The handler layer implements the architecture DESIGN describes with
almost no deviation, and the two deviations found (m-3.1's unvalidated
hub move, n-3.3's ignored parameter) are small consistency gaps rather
than invariant breaks. The purity guarantee - the thing this whole
review most needed to hold - held under a complete read. The recurring
defect class is unchanged from Part 2: refactors leave stale prose
behind (four more instances), which is a comment-hygiene problem, not a
correctness one. No Critical findings; the strongest single function in
the project so far (`end_level`) is here.

---

## Part 4 - Skills, effects, AI (~7.2k lines)

**Scope:** `skill.zig` (203), `effect.zig` (332), `skill_helpers.zig`
(743), `ai_select.zig` (149), `ai_threat.zig` (113), `ai_movement.zig`
(676), `utility_skills.zig` (47), all 44 `src/skills/*.zig` (4,657), all
9 `src/effects/*.zig` (296) - read in full. The combat brain: the
Skill/Effect interfaces, the one cast-selection algorithm, movement-mode
selection, and every skill/effect recipe.

### Invariant verification

- **The 18-callback Effect interface has ZERO dead contract surface.**
  Machine-verified: every one of the 18 callbacks has exactly one
  consuming site in the handlers (the grep walk in Part 3's territory
  confirmed each). The plan's open question ("is every callback actually
  consumed, or is there dead contract surface?") answers cleanly: the
  interface is exactly as wide as its consumption, and 6 of the 9 effects
  are pure additive-modifier records (bull_form is 10 lines: name,
  description, `.{ .distance = 10 }`).
- **Integer-only: holds across every skill/effect/AI file.** No floats
  anywhere in the combat math; damage multipliers are integer
  (`base + base/2`), the momentum conversion is log2, all distances are
  Chebyshev i32.
- **Effective-value discipline: holds at every gameplay read.** Every
  skill reads range/radius/distance/damage/durations through
  `getEffective*`; raw reads appear only as inputs to those calls (the
  one exception the design documents: runtime counters). The
  multiplier-ordering rule (multiply the fully-modified total) is
  followed at every scaling site (Impale/Skewer fold the doubled
  momentum INSIDE, Bash/Powerful Shot halve the effective total for
  collision).
- **`deals_damage` is required and every value I read is defensible** -
  including the judgment calls: That-Which-Explodes is false with the
  rationale documented inline ("the threat model measures proactive
  reach"), Howl/Swap/Blink false, all attack skills true. The
  no-default field means a forgotten flag is a compile error - the
  machine-enforced version of the convention.
- **Determinism: every selection is a total order.** Focus-fire tail
  (health, distance, entity_index), keyed picks (collide-preferring,
  unstunned-preferred), strict-< scan conventions with comments naming
  the tiebreak at each site, the AoE spiral, `(y, x)` center scans.
  `bestCasts`'s strictly-greater + slot-order implementation matches
  DESIGN's selection rule exactly.
- **Purity: skills are pure recipes.** Every `useSkill` returns an event
  list (through `ownedEvents`, which interleaves the pacing waits for
  free); no skill touches SessionState or files; effects return event
  lists from their hooks. The two machinery events that exist
  (`adrenaline_surge`, `reset_weapon_cooldowns`) are justified by the
  documented definitions-reach constraint.
- **Performance lens (AI worst case at caps):** per enemy turn,
  `bestCasts` evaluates ≤8 slots; the heaviest option fns are the
  center-scans (Meteor/Flash Strike: ~range² tiles × entities =
  49 × 256 ≈ 12.5k ops); the re-evaluation chain multiplies by the
  number of casts in the turn, the sim-differential enhancers add one
  full re-evaluation each. Worst case ≈ low-100k simple integer ops per
  enemy turn at the documented caps - far below any frame budget. The
  EvalFrame memoization is what keeps consultation-heavy enchantments
  (stone_form/lingers/reaches scan every slot's options) from being
  quadratic. No perf concern; nothing worth measuring.

### Findings

- **m-4.1 (Minor, armed landmine) - `that_which_lingers`'s
  `playerPrepareSkill` returns a `create_effect` event.** Every other
  skill's prepare is a pure UI step (highlight or null); lingers' prepare
  APPLIES THE GAMEPLAY EFFECT (returns the exact create_effect its
  `useSkill` also returns). The interface contract (skill.zig's
  `player_prepare_skill_fn` doc: "A skill with `uses_targeting == false`
  is never asked... return null") says this function should return null -
  lingers is non-targeting. It is dead code today (the input layer goes
  straight to useSkill for non-targeting skills, so prepare is never
  called), but it is armed: any future caller of `playerPrepareSkill` on
  a non-targeting skill double-applies the effect - and `create_effect`
  STACKS durations on re-application, so the holder would get +4 turns
  instead of +2. Secondary inconsistency in the same file: its aiOptions
  passes `.target = caster.position` where every other self-cast passes
  `null` (ignored either way). Fix: `return null` + delete the dead
  prepare body.
- **m-4.2 (Minor) - the rating-scale comments disagree with their own
  code, in both directions.** The value-units scale is a load-bearing
  convention (skill.zig documents it; new skills copy their siblings'
  comments), and three files carry stale numbers: (1) heal.zig's
  aiOptions doc opens "one self-cast at 2 (a 20% heal ≈ one bonus-hit of
  value)" while the code returns `priority = 1` - and the SAME comment
  then correctly argues for 1 ("a flat below-full rating would tie the
  plain attacks at 1, where slot order would make Heal win"); (2)
  absorb.zig's comment says "the 4 must outrank Heal's 3 on the idol
  bar" - Heal is 1, not 3; (3) worldfire.zig's Skill-struct doc says "a
  single-target cast ties the basic attack at 3 and loses to slot order;
  a cluster rates 4" while its aiOptions doc and code say 1-per-target.
  These read as remnants of rating rebalances where the code moved and
  the comments didn't. Comment-only fix, but worth doing precisely
  because the scale is the convention new skills inherit.
- **m-4.3 (Minor, the doc-drift class grows to ~15 locations)** - three
  more shapes of it here: the fused doubled template lines "Self-cast -
  no meaningful target. / Self-cast - fires immediately." in six skill
  files (absorb, focus, heal, reflect, replenish, stone_form); the
  doubled `TargetCandidate` doc in skill_helpers.zig; and
  `damageTimesOneAndAHalf`'s doc block fused with
  `aoeKnockbackPriority`'s (two functions' docs merged into one block).
  Same disposition as m-2.2/m-3.2: one cleanup pass.

**Security lens:** skill damage math is bounded on legal paths (max ~72
from a 10-damage weapon × 2 + momentum 32 + bonuses) - nowhere near the
i32 `@intCast` limits in `applyModifier`; no crafted-log amplification
is possible through skill payloads (machinery, never seeded).

### Highlights

- **H-4.1 - 44 skills, one shape.** Reading all 44 back-to-back: every
  file implements the same five functions, reads every authorable number
  through `getEffective*`, composes generic events via `ownedEvents`
  (pacing for free), selects targets through the shared helper family,
  and rates itself in value units with the rationale inline. The
  consistency IS the achievement - a new skill author has 44 correct
  templates and zero wrong ones to accidentally copy (the m-4.1/m-4.2
  exceptions are the only deviations found in 44 files).
- **H-4.2 - The Effect interface earns its width.** 18 callbacks, zero
  dead surface, and the width is consumed by genuinely distinct pipeline
  stages (the intercept-transform vs on-react split is documented at the
  interface and honored by every implementation - Reflect zeroes + emits
  in the transform stage, TWE explodes in the reactor stage, and the
  `triggers_effects = false` loop-guard on reflected attacks mirrors the
  design's counterplay rule exactly).
- **H-4.3 - The EvalFrame is elegant systems design.** 25 lines of
  in-progress set + memo table that make ARBITRARY skill-to-skill
  consultation safe with no structural restrictions - cycles terminate
  at the guard, memoization caps the per-pass cost, and the
  sim-differential's frame-inheritance (caller's in-progress set +
  simulated skill) mechanically prevents two sim-based enhancers from
  alternating through each other's simulations forever. The kind of
  design that replaces five structural rules with one mechanism.
- **H-4.4 - The rating comments (where correct) encode real design
  reasoning.** Heal's slot-order interaction, Drain's Absorb-vs-Heal
  priority note, Stone Form's live-beneficiary +1 ordering rule, the
  focus-fire rationale in skill_helpers - these aren't code
  restatements; they explain why a number is what it is, in the scale's
  own units, at the site a future author will edit.
- **H-4.5 - `deals_damage` as a required field is the right call.** The
  threat model, the movement modes, and the defensive-skill ratings all
  hang off one boolean, and making it non-defaulted turns "forgot to
  classify the new skill" from a silent AI deficiency into a compile
  error - while `point_blank_area_of_effect` (where a forgotten flag
  only makes the AI dumber) stays defaulted. The asymmetry is reasoned
  at the interface.

### Part verdict

The skill/effect/AI layer is the most uniform 7k lines in the project -
one interface, one selection algorithm, one movement-mode selector, 53
small files that all fit the shape. The AI design (unified options, the
frame, the sim differential, the value-unit scale) is genuinely
sophisticated and, unusually for game AI, fully deterministic by
construction. The defects found are two comment-hygiene classes and one
armed-but-dead landmine; nothing reaches the replay guarantee, and the
performance lens finds nothing worth measuring at the documented caps.

---

## Part 5 - Config layer: parser, loaders, writers, file IO, session logs (~13.5k lines)

**Scope:** `parser.zig` (1,433), `loaders.zig` (6,480), `writers.zig`
(1,516), `file_source.zig` (1,411), `game_zip.zig` (598), `zip_reader.zig`
(474), `zip_writer.zig` (152), `content_hash.zig` (258),
`validation_replay.zig` (519), `session_log.zig` (904),
`session_log_bundle.zig` (590). Read in full except loaders.zig's
~2,400 test lines (read in large part; covered systematically in Part
11, which reviews the test suite anyway) - stated plainly rather than
papered over.

This is the security lens's home ground: untrusted parsing (custom
missions, saves, logs), the zip seams, path handling.

### Security-lens verification

- **Zip-slip: comprehensively defended.** `zip_reader.isUnsafeZipEntryName`
  rejects absolute paths, `..` segments, backslashes (correctly treated as
  hostile outright, not just a separator variant), NUL bytes, empty
  segments, and empty names - applied BEFORE the first write by both
  importers, with edge-case tests. `isOsZipJunkEntry` handles the OS-zip
  noise so an OS "compress folder" round-trips clean. The EOCD scan takes
  the LAST record occurrence (junk in a comment-tail can't shadow the real
  one). Zip64 and encryption are rejected with descriptive errors; CRC-32
  is verified on every entry.
- **Decompression bombs: capped at the right place.** The game-folder
  import checks entry-count (65,536), per-entry (512 MB), and total
  (2 GB) caps over the CENTRAL-DIRECTORY HEADERS - pass one, before any
  entry is decoded or written - and the tests prove it by patching
  central records of empty entries (no actual bytes needed). The dry-run
  decode pass (pass three) then validates every local header + CRC +
  size WITHOUT writing, so a corrupt archive also fails whole; the write
  pass streams one entry at a time through a reset arena. OPEN: the
  MISSION zip import's call site (editor/mission_io.zig) is Part 9's -
  its cap coverage is verified there.
- **Hostile numeric tokens: fail as null/error, never panics.**
  `asU32`/`parseInt` return null on overflow; a huge `Layout N` count is
  bounded by the actual file (EOF → `error.LayoutTruncated`); unparsable
  versions fail the hard version gate; enum values are exact-match.
- **Balance bounds verified at every site.** Every parsed gear-stat
  field across `parseEntityDefinition`, `parseItemEntry`, and
  `parsePlayerLoadoutFields` routes through `boundedU32` (clamped +
  warned) - I checked each of the ~20 sites individually. Entity base
  stats stay unbounded by documented design.
- **Upload/download seams:** the browser-upload JS sanitizes filenames
  (allowlist regex + leading-dot fix) and the marker write-order
  guarantees bytes-before-signal. The download seam formats its path +
  name into single-quoted JS - see the hardening note below.

### Findings

- **m-5.1 (Minor, security hardening for the server seam) - FileSource
  has no path normalization of its own.** `readFile`/`writeFile` pass
  paths straight to the dir handles; `..` components and absolute paths
  are not rejected at the seam. Safety today rests on three other
  layers, all verified: zip entry names validated at the zip seams, JS
  filename sanitization at the upload seams, and all live internal
  paths being fixed constants (crafted-log writes can never fire -
  `!replaying`-gated). The residual exposure: a crafted session-log
  bundle or validation replay can seed RECONSTRUCTION reads at paths
  outside the persistent dir (e.g. `start_mission{mission_path =
  "../../..."}`) - a local-only read whose parseable fragments (a
  mission name) can surface in the UI; on the future server-revalidation
  path, "crafted log" becomes a NETWORK input feeding lazy-disk reads.
  Recommendation: one `validateRelativePath` gate (reject absolute,
  `..` segments, backslash, NUL) at the FileSource readFile/writeFile
  seam - defense in depth at a single site, ~15 lines. Flagged as a
  must-do-before-server-seam item for Part 15.
- **m-5.2 (Minor, same class) - `loadSessionLogBundle` has no
  total-bytes cap.** Per-file reads are limited (256 MB), but a hostile
  bundle with many distinct-hash content copies can drive unbounded
  aggregate allocation during load - unlike the game import's 2 GB
  total cap. Harmless locally (the attacker already owns the disk);
  a hardening item for the server-side bundle/replay consumer.
- **m-5.3 (Minor, doc drift continues, ~17 locations total)** - the
  class now includes `boundedU32` itself: its doc comment is
  orphaned-and-truncated in parser.zig (cut mid-sentence above `asI32`)
  and split into fragments in loaders.zig (a stray "parse failure (same
  as `asU32`). See DESIGN..." line before `appendWarning`). Same
  one-pass cleanup as before.
- **n-5.4 (Nit) - the settings Metadata key whitelist reuses a const
  named `level_metadata_keys`** (comment says "shared", the name says
  "level") - a small naming debt that misleads on first read.

**Other verified-conventions:** the OOM-panics-inline convention holds
across all eleven files (allocation failures panic; input validation
returns errors with errdefer cleanup sweeping partial builds - the
malformed-fixture leak tests exist and are leak-checked under
`testing.allocator`); writers are the loaders' true inverse with
round-trip tests at every level (save, settings, editor mission through
the real `buildEditorMission` reload path, semantically compared because
palette re-dedup can reorder); the editor writer's coupling contract
(every written key in the parser's vocabulary) is explicit and tested;
the save-time custom-stem normalization self-heals renamed missions;
spawn-relative normalization lands once at the load seam in both
loadLevel and loadHub.

### Highlights

- **H-5.1 - The four-pass hostile-zip import is the best code in this
  part.** Headers (all names + sizes, no data) → caps → names → dry-run
  decode → streamed write, each pass failing WHOLE before the next
  begins, with tests that construct the exact hostile shapes (a
  traversal name sorted before a valid entry, proving zero writes;
  patched central records proving caps fire before decode). The split
  reader API (headers vs one-entry extraction) is what makes
  validate-everything-then-stream possible. For a hand-rolled zip path
  with no third-party library, this is exemplary.
- **H-5.2 - Session-log bundles make saved sessions exactly
  reproducible.** Hash-verified content copies, dedup by hash
  (identical bytes stored once; the mid-session-overwritten autosave
  correctly becomes two copies), monotonic-manifest rejection (the
  binary-search invariant defended at load), tamper detection via hash
  mismatch, and content-files-first write ordering so a half-written
  bundle fails to load cleanly. The tamper/non-monotonic/bare-log
  rejection tests each construct the exact hostile artifact.
- **H-5.3 - The per-format grammar design.** One expected-headers list
  serving as both grammar and validation (they cannot drift apart by
  construction); the counted-Layout rule solving "a row can spell any
  header" with the rejected alternatives documented; version-paired
  strictness (current-version + bare Layout = error, legacy files keep
  loading). The parser is small, total, and hostile-input-safe.
- **H-5.4 - `session_log.zig`'s comptime-generic serialization with
  compile-time shape policing.** Unsupported shapes are compile errors
  at both the writer and reader; the string-safety conventions
  (flattened top-level strings, the indexed multi-line encoding for
  string-bearing struct slices) are documented at each mechanism and
  pinned by a representative-shapes test that also serves as the
  encoding's reference. The optional-union-payload null-as-tag
  convention is handled symmetrically on both sides.
- **H-5.5 - The loaders' ownership discipline.** Every loader documents
  its borrowed-vs-owned contract (freeEditorBuild's doc is a per-kind
  ownership spec); errdefers sweep partial builds on every error path;
  tests free the parse sections BEFORE the assertions so any borrow
  would be a use-after-free by construction; malformed-fixture tests
  run leak-checked. This is the hardest bug class in manual-memory
  code, and it is systematically prevented rather than luck-dependent.
- **H-5.6 - validation_replay.zig is the server-check prototype done
  right.** Bracket checks encoding the file's contract, identity gate,
  checking-mode replay reuse, derived turns, the personal-best
  overwrite decision as a directly-tested pure helper, and the medal
  collision edge case documented in the test. When the server seam
  lands, this file is the client-side blueprint it should mirror.

### OPEN items

- Mission-zip import cap coverage (editor/mission_io.zig) - Part 9.
- m-5.1/m-5.2 carried to the Part 15 security-posture verdict as
  pre-server hardening items.
- `start_hub`'s `data/campaigns/{campaign}/...` path shape vs the
  persistent-dir `campaigns/...` convention - a campaign-editor-slice-2
  path decision, not a defect today (single shipped campaign).

### Part verdict

The config layer is the most security-conscious code in the project -
the untrusted-input posture (warn + degrade, never reject, never crash;
fail-whole on hostile archives) is applied consistently and tested at
the exact hostile shapes. The two real gaps found (path normalization
at the FileSource seam, bundle size caps) are invisible locally and
become live only at the server seam - which is exactly when the project
planned to revisit this code. The recurring defect class remains stale
prose. No Critical findings; nothing that corrupts saves, logs, or
missions under any input I could construct on paper.

---

## Part 6 - Input layer (~12.2k lines)

**Scope:** `input.zig` (1,651), `input_handlers.zig` (5,956),
`input_gestures.zig` (1,467), `console.zig` (2,080), `dump_walker.zig`
(856), `ui/keybind_edit.zig` (237). Method, stated plainly: `input.zig`
and `keybind_edit.zig` read in full; `input_handlers.zig` read via its
structure map plus full reads of the core regions (the fired-actions
sound choke point, the escape chain, the keybind-edit mutation
machinery, the text-field commit resolution, both tile-cursor
resolutions, handleIdleInput's branch heads and hub/main-menu arms),
with the long per-action consumption switches cross-verified against
the `applyAction` map and the orchestrator handlers read in Parts 2-3;
`input_gestures.zig` verified at its trickiest handlers (camera pan,
drag threshold, right-click disambiguation); `console.zig` core
structures + queue/merge read against the DESIGN section (read in full
in Part 1); `dump_walker` invariants verified at their enforcement
sites. The gesture/switch arms not quoted above follow shapes already
verified three times over in earlier parts.

### TODO-item resolutions (this part's assigned questions)

- **Vestigial `!replaying` gates at input-layer sound sites: CONFIRMED
  DEAD, disposition = keep + document.** Verified by call graph:
  `handleAnytimeInput`/`handleIdleInput`/`resolveTileCursor` are called
  ONLY from `main.zig`'s update path (lines 250/261/356); every replay
  origin (`replayTo`/`replayToWithIdleTracking`/`restoreTo`/
  `reconstructFromEventLog`) drives `processEvent` directly via the
  `apply_event` pointer and never touches `update()`. The ~10 per-site
  gates are therefore unreachable - exactly as the TODO hypothesized.
  Recommendation (matching the TODO's own no-churn guidance): one
  comment at the choke point (`dispatchFiredActionSounds` already keeps
  its gate "for convention") stating "the input layer is live-only by
  construction - replay drives processEvent directly; these gates are
  defense-in-depth against a future call path, not live behavior."
  That converts the dead defense from cargo-cult risk into documented
  intent, at zero churn.
- **Lost mouse-up drag cancel (focus loss): confirmed still open.** No
  focus-loss handling exists in input_gestures - a release outside the
  window leaves the drag latched, as TODO documents. Agree with its
  tracking; worth landing whenever window-events are next touched.
- **Mouse-owns-the-frame arrow-drop: confirmed by code.**
  `resolveTileCursor` gives the mouse the whole frame on
  `mouse_moved_this_tick` (any position change) - the arrow edge is
  consumed, not deferred. Agree with TODO: only worth touching if
  eaten taps are observed with a hand resting on the mouse.

### Findings

- **m-6.1 (Minor, doc drift #18 - the most semantically misleading
  instance yet) - `input.zig`'s `InputState` doc claims the WRONG state
  home.** The doc on the type reads "Lives on GameState so it persists
  across ticks" - but `InputState` lives on **SessionState**
  (`session.input_state`), and the entire replay-safety architecture
  depends on that placement (held-key state must never be in snapshots
  or be reconstructed by replay; DESIGN → Replay & Side Effects states
  the rule this placement implements). A reader of the doc comment
  would conclude held keys are undoable and replay-reproduced - exactly
  backwards. One-line fix; worth prioritizing within the drift-cleanup
  pass because this one teaches a false architecture fact, not just a
  stale detail.
- **n-6.2 (Nit) - the drag-threshold distance compare
  (`dx*dx + dy*dy > threshold*threshold`) is hand-written six times
  across input_gestures.zig** (drag promote, camera pan, marquee,
  right-click cancel ×2, editor move-drag). A one-line
  `pointerBeyondThreshold(press, position)` helper would collapse them
  and make the strict-`>` convention single-sited.

### Verified in this part

- **The dispatch convergence is exactly what DESIGN claims**: ONE pass
  over the bindings in `translateInput`, every fired action folding
  through `applyAction` (the same seam as button releases and console
  commands), same-frame degeneracies resolved by documented rules
  (first-listed-wins, the skill-slot guard), and the ctrl+S
  missing-dispatch-line bug class structurally dead - pinned by a test
  that documents the shipped regression it guards.
- **Hybrid precedence**: specificity ordering (plain yields to chords),
  subset modifier matching (plain bindings fire under held chords),
  equal-specificity first-listed-wins, cross-context same-combo pairs
  resolved by the context gate - all implemented in
  `bindingFires`/`isSuppressed` exactly as DESIGN specifies, each rule
  pinned by a dedicated test including the three-binding specificity
  ladder and the un-held-modifier non-competitor case.
- **The repeat whitelist** gates synthetic edges inside the per-binding
  check (movement cursors, undo/redo, skip, error-scroll only); the
  rollover fallback (`cursor_press_direction`, real edges only, repeats
  excluded) prevents both the swallowed-tap and the repeat-drift
  oscillation - with tests for both directions.
- **`resolveTileCursor`'s trigger/derive split** (edges trigger, held
  keys derive the vector) and gap-crossing ray search behave as
  designed; the editor arm deliberately skips tile-membership clamping.
- **The keybind-edit machine** (listening/picker/pending + capture
  seam) mirrors the text-edit suppression model, uses fixed buffers
  (no allocation, no lifetime), resolves the Enter-captures-vs-
  Enter-confirms ambiguity by phase ordering with the safety argument
  documented, and its steal scan uses the correct co-fire predicate
  (`bindingContextsCoFire`, not intersection - the slice-4 bug the
  tests caught).
- **The console channel** follows its DESIGN exactly: BoundedText
  fixed-buffer strings everywhere (zero allocation between parse and
  merge), the SPSC ring with yield-spin backpressure, id interning to
  static slices (the lifetime invariant), `wait idle` releasing on the
  first frame the game accepts input, and the verb table as the single
  vocabulary declaration with the both-ways examples test.
- **dump_walker's safety invariants are enforced by construction, not
  convention**: const propagates from the `*const` root (mutation is a
  compile error), pointers render as `<pointer>` and are never
  followed, no method calls (field reads + @typeInfo only), union
  descent is active-tag-checked, indexes bounds-checked with truthful
  errors, and the canary test asserts a deep-path battery leaves the
  state bit-identical.
- **The camera-pan anchor math** (press-anchored solve keeping the
  grabbed world point under the cursor, threshold-latched engagement)
  is clean and matches DESIGN; the blocking-UI suppression and the
  stale-state clears on non-world screens are both present.

### Highlights

- **H-6.1 - `dispatchFiredActionSounds` + the outcome-gated exclusion
  set.** One choke point over `fired_actions` for the action-layer
  sound, with the exclusions (`undo`/`redo`/`swap_weapons`/`cancel`/
  `skip`/skill slots) each carrying its rationale inline - a no-op
  stays silent, and the comment names the shipped double-play bug
  (.skip's absence) that motivated the set. Per-action policy now has
  exactly one place to live.
- **H-6.2 - The binding test suite teaches its own bug history.** The
  ctrl+S dead-keybind test, the Enter dual-bind context tests, the
  Digit1 cross-context pair, the rollover-swallow fallback, the
  repeat-whitelist escape-held case - every test I read names the
  shipped defect it prevents. This is the "tests as regression
  memory" discipline at its best.
- **H-6.3 - `keybind_edit.zig` is a small state machine done
  perfectly.** 237 lines, three phases, a capture buffer with no
  lifetime question, the phase-ordering resolution of the Enter
  ambiguity documented at the site, and the whole machine off the undo
  timeline with the mutation confined to Confirm. The kind of file
  that makes the feature look easy in hindsight.
- **H-6.4 - The trigger/derive split in cursor resolution.** Edges are
  triggers, held state is the vector, real-press edges are the rollover
  fallback, repeats are deliberately excluded from fallback so a
  deliberately-held opposite pair stays frozen. Three interacting
  rules, each with a dedicated test, each comment explaining the
  physical-input reality it models (two presses rarely land in one
  tick; per-key repeat timers drift).
- **H-6.5 - The console channel's zero-allocation discipline.**
  BoundedText by value everywhere, interning to static slices at merge,
  one-command-per-frame cadence identical to synthetic key repeat -
  "another input channel, not a dev tool" is enforced by making the
  console ride the exact same pipeline as hardware.
- **H-6.6 - `dump_walker` makes its safety contract a compile-time
  property.** The const-propagation trick (mutation anywhere in the
  walker is a compile error) plus the never-follow-pointers rule plus
  the canary test - reflection over live game state with an
  execution-free guarantee, which is rare for this kind of feature.

### Part verdict

The input layer implements DESIGN → Input faithfully and completely -
the convergence, the precedence model, the capture seams, and the
console channel all check out against their settled design, with tests
that read as annotated bug histories. The single defect found is a
doc comment stating the opposite of a load-bearing architectural fact
(m-6.1) - the same drift class as before, but this time with real
teaching power, so it tops the cleanup list. Two TODO-tracked
edge-case items were independently confirmed as tracked-and-agreed.
The vestigial-gate question is settled with a concrete no-churn
disposition.

---

## Part 7 - View + raylib platform seam (~10.5k lines)

**Scope:** `view.zig` (5,757), `src/raylib/` (backend 772, textures 671,
draw 649, text 527, audio 415, input_poll 363, diagnostics 212,
conversions), `diagnostics.zig` (491), `browser_url.zig`,
`transient_allocator.zig` (47), `font_codepoints.zig` (454). Method:
`view()`'s full body + camera/overlay/anim/occlusion/census regions read;
the raylib files read at their core mechanisms (render model, shader
selection, caches, key tables, init order, draw paths) with structure
maps guiding; DESIGN → Platform Seam (read in full in Part 1) used as
the verification contract throughout.

### Machine-verified lenses

- **The aarch64 miscompile rule (tint shape): CLEAN.** Grep across the
  seam finds no if/else EXPRESSION whose branches call extern-struct-
  returning functions with the extern call as the value's only
  consumer. The one near-miss (text.zig:512,
  `if (eql(label.color, default_tint)) theme_lightest else
  label.color`) is the rule being FOLLOWED: it pre-selects the plain
  `types.Color` source value and converts once. `conversions.zig` is
  the single conversion site, exactly the design's shape.
- **The emscripten allocator rule: CLEAN.** `page_allocator` appears
  only in the three host report tools (native-only builds, outside the
  rule); `transient_allocator.zig` implements the documented
  platform split with the full black-screen rationale in its header.
- **Camera clamp math verified against DESIGN line by line**:
  `clampCameraAxis` implements flush bounds + margin band +
  centered-when-fits; `computeCamera` applies the pan-slack
  distinction and the editor free-pan exemption (with the
  `level == null` guard so playtest/validate keep the level clamp);
  `cameraViewRegionFor` implements the panel fallback; both the input
  and render cameras route through the same function.
- **The lockstep comptime guards are real and bidirectional**:
  input_poll's key table ↔ `types.producible_key_ids` checked both
  directions at compile time (a table id missing from the list, or a
  list entry with no table row, is a build break); the SDF constants
  carry a `@compileError` binding backend ↔ generator ↔ shader decode.

### Findings

- **m-7.1 (Minor, doc/impl drift) - world-layer missing art draws
  NOTHING, not the promised magenta.** The magenta fallback exists in
  the UI draw paths (`drawSprite`, `drawNineSlice`: `getTexture(...)
  orelse { drawRectangleRec(destination, magenta); return; }`) but the
  WORLD draw paths (`drawWorldSprite`, `drawSpriteDrawable`,
  floating-icon overlays) do `getTexture(...) orelse return` - a
  missing world sprite draws nothing at all. Meanwhile the docs
  promise magenta universally: DESIGN → Platform Seam says "MISSING
  art draws a magenta box (dev-friendly)", textures.zig's own header
  says "cache null and fall through to the magenta fallback at draw
  sites", the loaders' custom-art warnings say "will render as
  fallback", and the art_report's premise ("a missing sprite draws
  magenta until real assets land") is the artist's shopping-list
  signal. Net effect: a custom mission with unresolvable ENTITY art
  renders invisible entities in-game - worse than magenta for an
  author debugging by eye (the load warning and the Revalidate art
  report do catch it textually, but "renders as fallback" promises
  something visible). Fix is two lines (draw the magenta rect in the
  world paths' null arms, at the drawable's own destination rect);
  alternatively, if invisible-world-missing is deliberate, DESIGN +
  the warning text need the split stated. Either way the current
  state is the docs promising what the code doesn't deliver.
- **n-7.2 (Nit) - the world paths' early-return-on-missing is the
  same `orelse return` shape three times** - fold into m-7.1's fix
  rather than a separate change.

### Performance-lens verdicts (the assigned items)

- **Stripe-scope-per-tile (~2 batch flushes per highlighted tile):
  agree with TODO - fine at this scale.** Confirmed at the code level
  (draw.zig opens/closes a stripe scope per overlay draw, and
  `endShaderMode` flushes the batch). A 20-tile move range is ~40
  small flushes/frame - trivial against any GPU's draw-call budget;
  the two-pass restructure (all non-outline overlays, then one scope)
  is the right fix IF profiling ever shows it, exactly as TODO
  records.
- **`sprite_bounds` per-frame rebuild: fine, TODO's note stands.** The
  EXPENSIVE half (the opaque-bounds decode) is backend-cached
  (`sprite_bounds_cache`, one decode per sprite, process lifetime);
  the per-frame cost is a fresh `StringHashMapUnmanaged` in the frame
  arena populated with ~16-256 entries - dozens of small arena
  allocations, absorbed by the arena reset. The
  "bundle-backend-derived-values-if-a-third-lands" note in TODO is
  the right disposition.
- **Web frame-time dips: remains measure-first.** The candidate costs
  are visible in the code (full `view()` rebuild per frame - by
  design; the render-gate skips `view()` during drains, so the dip
  aligns with the per-turn drain+view+render frame); no paper
  analysis can split drain vs view vs render. Agree with TODO: a
  devtools Performance capture while reproducing, then decide.

### Verified in this part

- **view() is pure over (GameState, SessionState, RenderContext)**:
  every allocation lands in the frame arena, the clock is read only
  via the session clocks (never wall-clock), and the z-order census
  test pins the emission ladder the Escape chain mirrors.
- **The letterbox/render model**: one `viewTransform` for the blit +
  its inverse for the pointer; the render target decoupled from the
  4K design space via `beginMode2D` zoom; `blitTransform` separate;
  dual GLSL variants (330 / 300 es) comptime-selected per target;
  premultiplied alpha carried consistently (premultiply at upload so
  downsampling blends in premultiplied space; premult tints at every
  translucent draw; the rationale documented at conversions.zig).
- **The texture store's four caches** with their deliberate
  asymmetries: bases null-cached (few, all shipped), layers
  miss-not-cached (the sound-designer iteration loop), outline +
  composite-inset caches keyed by composed strings, bounds cache
  feeding `RenderContext.sprite_bounds`; the custom-art dims gate
  applied at all three decode sites.
- **The audio subsystem**: device-open failure degrades to silent
  no-ops; the music-first load order (the stb_vorbis pointer +
  format-init gotchas) is implemented as documented with the
  lifetime-owned bytes; layer volumes applied per frame.
- **The SDF text pipeline**: build-time atlas (zero metric drift),
  the clamp-floor rationale (the ghost-squares bug) documented at the
  constant, the GRAY_ALPHA swizzle fix present, the zero-outline-
  width-must-pair-with-transparent-color rule enforced in the shader.
- **Diagnostics**: end-of-frame flush after present (never mid-draw),
  one-shot section policy, best-effort writes throughout, the
  first-draw probes riding the draw path without perturbing it.

### Highlights

- **H-7.1 - The lockstep comptime guards.** Two independent
  bidirectional compile-time consistency checks (key table ↔
  producible ids; SDF constants ↔ generator ↔ shader decode) turn
  cross-file drift into build breaks. This is the
  machine-walked-truth discipline applied to the platform seam,
  where runtime checking is hardest.
- **H-7.2 - The camera clamp as pure, documented math.**
  `clampCameraAxis` is a single pure function whose every rule
  (flush, margin, centering, slack) is named at the site;
  `computeCamera` threads the pan/automatic distinction and the
  editor exemption with the playtest guard called out. The hardest
  "why is the camera here" questions in the game are answerable by
  reading one function.
- **H-7.3 - The z-order census test.** view()'s emission ladder is
  pinned by a test that forces every overlay surface open and asserts
  the canonical order - the mechanism that keeps the Escape chain and
  the renderer from drifting, born from a real drift bug, exactly the
  exhaustiveness-over-pinned-windows pattern DESIGN → Testing
  prescribes.
- **H-7.4 - conversions.zig + the premultiplied-alpha discipline.**
  One 60-line file as the single Color/rect conversion seam, and the
  premultiply invariant (upload-time premultiply → premult blend →
  premult tints, with the dark-halo rationale at each site) carried
  without a single straight-alpha leak found.
- **H-7.5 - The texture store's cache asymmetries are designed, not
  accidental.** Null-cached bases vs miss-not-cached layers - each
  choice documented with its reason (few-and-shipped vs
  mid-session-iteration), the custom-art gate at every decode site,
  and the composite occlusion-inset cache keyed by stack composition.
  The caches read as a policy, not an accumulation.
- **H-7.6 - The magenta fallback where it exists is done right** -
  the UI draw paths' null arms draw the destination-sized magenta
  rect inline, the diagnostics first-draw probes observe the real
  draw state without perturbing it, and the 9-slice fallback covers
  the panel case. (See m-7.1 for the world-side gap.)

### Part verdict

The platform seam is where this project's hardest-won lessons
(miscompiles, black screens, audio banking) live, and the code shows
it: every trap has a comptime guard, a documented rationale, or a
probe. The two real observations are a doc/impl drift on the magenta
fallback's world-side coverage (m-7.1) and the confirmation that the
tracked perf items are correctly tracked. No Critical findings; the
rendering model, camera math, and cache policies all verify exactly
against their settled design.

---

## Part 8 - UI framework (~11.4k lines)

**Scope:** `ui.zig` (206, the facade), `ui/element.zig` (1,501),
`ui/state.zig` (381), `ui/text_input.zig` (596), `ui/tooltip.zig`
(688), `ui/emit.zig` (889), `ui/bottom_bar.zig` (340),
`ui/panels.zig` (1,897), `ui/screens.zig` (1,117), `ui/menus.zig`
(3,893). (The three editor UI files are Part 9's.) Method: the
classification and known-gap checks run as machine greps over the
whole tree; the core mechanisms (Rect algebra + boundsOf, UiState's
field inventory, tooltip placement + wrap, the emit helper family,
the facade) read in full; the builder files verified at their
conventions (windowed emission, row-scroll, the two-column settings
grid) via structure + spot reads, with their census tests deferred to
Part 11.

### Machine-verified: the UI state classification HOLDS

The four-class rule (DESIGN → UI Framework → UI state classification)
was checked in both directions by grep over the whole tree:

- **Class 1 (semantic surfaces on GameState): ZERO direct production
  writes outside the event-driven methods.** Every
  `ui_surfaces.*_open = ` / `open_middle_panels[...] = ` /
  `inspected_entity_index = ` hit outside types.zig is a TEST fixture
  (handler_tests, input_tests, console tests setting up escape-chain
  scenarios) - legitimate test setup, not drift. All production
  mutation flows through `toggle_ui_surface`/`inspect_entity` events
  → the methods.
- **Classes 2-4 (UiState): ZERO handler writes.** No file under
  `src/handlers/` or `src/editor/handlers.zig` touches
  `session.ui_state` - the input layer owns those writes, exactly as
  the classification demands.

This is the rule the whole surface-gating legality architecture
(Part 2's `actionTriggerSurfaceOpen`) depends on, and it is real.

### Known-gap confirmations (TODO items verified as accurately tracked)

- **text_label boundsOf placeholder: confirmed.** `boundsOf`'s
  text_label arm reports a `font_size` square (element.zig:979) - the
  documented placeholder. Agree with TODO: wire to
  `measureSpanWidth` only if/when a text element needs a tooltip.
- **Tooltip cross-axis clamp degenerate case: confirmed at the
  code.** `placeTooltip`'s fallback clamps to screen bounds only
  (`clamp(fallback.x, 0, @max(0, screen_w - tooltip_width))`) - on an
  oversized tooltip the clamp can pull the panel back over its
  source. The `@max(0, ...)` guard for the
  tooltip-larger-than-screen case is present and documented. Agree
  with TODO: rare in practice, revisit if observed.
- **The inspect-panel duplicated recipes (skill-button + gear-slot
  visuals inlined vs emitSkillButton/emitGearSlot): tracked in TODO
  as a deliberate deferred cleanup; confirmed the description still
  matches the code shape.** No new assessment needed.

One non-finding worth recording: menus.zig's zero emit-helper count
is NOT the duplication class - the emit helpers are compound VISUAL
recipes (panel-backed buttons, icon buttons, skill buttons with
cooldown overlays), while menus.zig's inline sites are plain
`.button` element appends - the primitive vocabulary itself. No
`emitButton` helper exists because a bare button needs no recipe.

### Findings

- **n-8.1 (Nit) - menus.zig (3,893 lines) carries five distinct
  surfaces in one file** (main menu + credits + tips + the load-save
  browser + the whole settings screen incl. the keybinds tab). The
  sibling files split at one-surface-per-file granularity (screens,
  panels, bottom_bar); a per-surface split of menus.zig would match.
  Purely organizational - optional polish, no drift found across the
  surfaces.

### Highlights

- **H-8.1 - The UI state classification survives machine
  verification.** Two whole-tree greps, zero production violations in
  either direction. A design rule this load-bearing (the legality
  gates, the replay reproduction of surfaces, the wholesale resets)
  being enforced by discipline alone - and holding across ~145 files
  and 764 commits of agent-driven change - is the classification's
  design quality made visible.
- **H-8.2 - UiState reads as the classification's reference
  implementation.** Every field's doc names its class and its
  consumer: "`keybind_scroll_offset`: the index of the first visible
  row... clamped authoritative in the builder"; "`tips_index`: the
  settings_tab convention: a view affordance"; the footprint draft's
  off-timeline rationale. A new contributor learns the rule by
  reading the fields.
- **H-8.3 - `placeTooltip`'s side-preference design.** Four
  candidates in preference order, first-fit without clamping, a
  documented degenerate-case fallback with the clamp-guard math
  explained - and the whole tooltip layer written against the
  measurement seam (`measureSpanWidth`/`lineHeight`) so layout is
  deterministic and testable without the renderer.
- **H-8.4 - The wrapRow hard-break discipline with its bug story.**
  The newline test's comment carries the full diagnosis (raylib's
  DrawTextEx breaks on `\n` with its own advance, overlapping the
  measured layout - the startup-warnings popup bug). Layout and
  renderer agree by construction now; the test is the memory.
- **H-8.5 - One row-scroll convention, every surface.** Error popup,
  load-save browser, mission browser, keybinds list, inspector,
  level tabs: offset = first visible row, one wheel notch = one row,
  lower clamp at the input site, upper clamp authoritative in the
  builder (the only place that knows the count), whole visible rows
  only. I found no surface that deviates.
- **H-8.6 - The facade holds.** 13 internal files behind one
  `ui.X`-stable re-export surface; consumers never import the
  internals, so the file granularity could change (see n-8.1)
  without touching a single consumer.

### Part verdict

The UI framework is the layer with the fewest surprises so far: the
one architecture rule that matters most here (the state
classification) is machine-verified clean, the three known gaps are
all self-identified in TODO with accurate descriptions, and the
builder conventions are uniform across surfaces. The only new
observation is organizational (menus.zig's size). The
deferred-to-Part-11 census tests will complete the picture.

---

## Part 9 - Editor (~13.7k lines + its UI files' tests)

**Scope:** `editor/planning.zig` (1,266), `editor/handlers.zig`
(1,680), `editor/mission_io.zig` (847), `ui/editor_shell.zig`
(2,253), `ui/editor_inspector.zig` (5,293), `ui/editor_pickers.zig`
(2,351). Method: the editor mechanics (planners, placement
invariants, selection reconciliation, the commit chain, the save/
import paths, the uuid mint, the clamp-bounds pattern) read at their
implementations; the editor UI files verified at their conventions
(active-tool outlines, windowed inspector emission, picker framework)
via structure + spot reads, with DESIGN → Level Editor (read in full
in Part 1) as the contract. The inspector's census tests are Part
11's.

### The Part 5 open item resolves as a FINDING

- **m-9.1 (Minor today, Major at the online-services milestone,
  security) - the mission-zip import lacks the game import's bomb
  caps.** `importMissionFromZip` (mission_io.zig:720) calls
  `zip_reader.readZipArchive` - the JOINED API that fully extracts
  every entry into the frame arena - and only then checks an
  entry-COUNT cap (1,024). There is no per-entry or total-bytes cap,
  and crucially the count check runs AFTER the extraction
  allocations. A hostile zip with a small compressed payload and a
  huge declared `uncompressed_size` (u32, up to ~4 GB per entry)
  makes `extractZipEntry`'s `inflate` allocate that declared size
  upfront - before any cap sees it. Contrast `importGameFolder`,
  which checks all caps over the central-directory HEADERS (no
  allocation, no decode) in its first pass. Reachability today: web
  only (the mission browser's Import button / ctrl+I), player-
  initiated with a zip someone gave them - a tab kill under the
  in-memory model, no persistent damage. The realistic attack vector
  is the FUTURE mission database: download a hostile mission zip →
  import → memory bomb, at which point this is Major. Fix: mirror
  game_zip's pass one (headers → caps → then extract, streaming) -
  ~15 lines reusing the existing zip_reader split API, whose comment
  ("importers that must validate the whole archive before writing a
  byte... use this alone first") reads as if the mission import was
  MEANT to follow and never did.

### Verified in this part

- **Planner purity: as designed.** planning.zig imports nothing from
  state/session; every `planEditor*` fn is a pure function of Editor
  state returning an event list; the input layer fires only nonempty
  plans, the handlers keep the empty-plan return as the crafted-log
  defensive path - the three-way no-op contract holds.
- **The placement invariants are fail-fast with their rationale at
  each site**: "the click orchestrator clears occupants first, so
  reaching here occupied is a logic bug" precedes both
  `editor_place_entity` and `editor_place_item` guards.
- **Selection consistency is atomic within events**:
  `reconcileSelectionAfterPlacementDelete` (prune the removed entry,
  decrement indices above it, within the same event) runs at every
  placement-delete site; the delete arms process high-before-low for
  index stability; the reconciler is O(selection) with an
  early-exit when no relevant kind is selected.
- **The commit chain plans each link against live post-clear state**
  (the documented why: up-front planning breaks on shared covering
  decorations and index shifts), the exhausted link clears the
  selection, and the marker-veto triple layer (input gate → whole-plan
  empty → defensive marker arm) matches DESIGN.
- **The uuid mint is write-only** (randomness never enters GameState
  or a recorded event; the replay-safety rationale documented at the
  generator), with the session-scoped memo giving stable identity
  across re-saves.
- **The clamp-bounds snapshot pattern**: one implementation
  (`refreshEditorClampBounds`), invoked at exactly the level-switching
  events (open_editor both branches, set_active_level, add_level,
  delete_level); mid-edit tile changes deliberately never refresh (the
  author's viewport stays put); replay reproduces the snapshot by
  riding the same events.
- **The import's idempotent save-convention target, root-strip with
  mixed-shape refusal, and name validation before the first write**
  all behave as documented.

### TODO-item opinions formed

- **The marquee-crosses-marker UX trap (playtest-watch item): my
  recommendation is SURFACE, don't block.** When it bites, render the
  loss in the existing drag preview (the view already translates the
  selection outlines; entries whose translated target overlaps a
  marker would draw a "will be deleted" cue - a red or dashed
  outline) rather than vetoing the whole move. A veto is too blunt
  (a large legitimate move across a distant marker would die
  wholesale); the surface-the-loss approach matches the project's
  established warn-over-reject posture (balance bounds, art-spec
  reports). Decide from playtest texture as TODO says - but when the
  decision comes, the preview-cue is the shape I'd build.
- **The editor_inspector split (optional in TODO): agree with
  deferring.** The file has grown (4,649 → 5,293 since the note was
  written; 21 test blocks), but it is cohesive (one panel + its
  tests), and TODO's own criterion - "the census sweep shows how much
  of that test mass survives deletion" - is the right gate. Part 11
  will inform it.

### Findings

- m-9.1 (above).
- **n-9.2 (Nit) - editor_inspector.zig's growth continues** (5,293
  lines now vs the 4,649 in the TODO note) - the deferred split
  question stands, with Part 11's census review as the decision
  input.

### Highlights

- **H-9.1 - The planner/handler/input three-way split as
  drift-proofing.** The no-op conditions live ONCE (in the pure
  planners), consumed by both sides - the input gate and the handler's
  defensive return read the same plan, so "a click that changes
  nothing never records" cannot drift from "a redundant event in a
  log replays harmlessly." The design-review question "who owns the
  no-op?" has a single answer.
- **H-9.2 - The placement invariant panics teach their own
  contract.** Each guard site states what the orchestrator already
  guaranteed - reaching the panic IS the bug definition. This is
  fail-fast as documentation, not just as safety.
- **H-9.3 - The chained commit worklist is the right answer to a
  genuinely hard ordering problem.** Interactive edits with mutual
  interference (shared covering decorations, index shifts) cannot be
  planned up-front; planning each entry against the live state as its
  link pops, with the worklist carried in the event (replay-reproduced
  by construction), is an elegant fit of mechanism to problem - and
  the doc comment explains exactly why the naive design breaks.
- **H-9.4 - The write-only uuid mint.** Randomness at the input-layer
  side effect, never in state, with a session memo for stability -
  the replay-safe identity design in four lines of comment and
  fifteen of code.
- **H-9.5 - The clamp-bounds snapshot as a replay-safe cache.** A
  derived value refreshed only at the events that change its inputs,
  riding the undo timeline for free - the same pattern as the
  reconstruction cache's philosophy, applied to a camera nicety.
- **H-9.6 - The import path's OS-zip empathy.** Root-strip for the
  "compress folder" shape, junk skipping, mixed-shape refusal with
  the popup explaining what went wrong, idempotent re-import via the
  save-convention dir - the design treats real-world zips as the
  primary input and hostile ones as the handled edge.

### Part verdict

The editor is the project's largest subsystem and it verifies almost
perfectly against its unusually detailed DESIGN section - the
planners are pure, the invariants fail fast with rationale, the
selection algebra is atomic, and the save/import round trip is
self-healing. The single real defect found (m-9.1) sits at the seam
between the editor and the config layer: the mission import never
inherited the bomb-cap discipline its sibling game import
established, and the fix is small and pointed. The two tracked
editor questions (marquee trap, inspector split) both got concrete
opinions for the day they're decided.

---

## Part 10 - Composition, platform entries, build system (~5.5k lines)

**Scope:** `main.zig` (2,754), `session_setup.zig` (960),
`native.zig` (285), `web.zig` (325), `build.zig` (981),
`build.zig.zon`, `tools/sdf_atlas_generator.zig`, the generated
files (checked as build artifacts, not hand-reviewed). Method:
update()/frame() read in full at their wiring; session_setup read at
its teardown + tests; the entries read at their drivers; build.zig
read at its structure + the exclusion/generation contracts.

### The composition question, answered

**main.zig's `update()` is composition with rationale, not accreted
policy.** The ~300-line body is a sequence of delegations - press/
release dispatch, cursor resolution, the sound choke point, anytime
input, the gates, the gesture handlers in their documented order, the
wait drain, processEvent-or-idle - and every seam carries a comment
explaining WHY it sits where it sits (the M2 text-edit arbitration's
proceed/consume split; the wait's baseline-drain assumption spelled
out with its "true for swap_hands, the only anytime event-pusher
today" caveat; the drag-yields-to-release ordering). The two frame-
level exceptions (text-field keyboard resolution, the button payload
relay) are exactly the documented restricted set. The frame() drain
loop, render gating, and the anim/sound/clipboard drains follow the
same pattern. Verdict: the file has grown large, but every line of
its growth is delegation with its ordering rationale attached - the
review question ("composition or accretion?") answers cleanly.

### Verified in this part

- **The session round-trip test** ("forward play == replay") lives
  here, at the composition root, arena-backed and driving the real
  processEvent machinery - the suite's crown test (Part 11 examines
  it structurally).
- **The StartupMemory teardown is compact and leak-checked**:
  `freeSessionSetup` frees the frame arena, the history (its deinit
  covering everything Part 2 verified), every retained bytes+sections
  pair, and the warnings; the overlay tests run under
  `testing.allocator`. The DESIGN-documented limitation (a re-boot
  from a deeper session relies on the deinit's symmetric frees rather
  than a driven test) remains a known-limitation line, confirmed
  accurately tracked.
- **The entries are thin and mirror-shaped**: native (blocking
  driver + console reader wiring + persistent-path resolution) and
  web (rAF driver + in-memory mount + re-boot + audio watchdog) each
  ~300 lines, with the platform-specific parts exactly where DESIGN
  says they live. The shared boot sequence duplication is minimal
  (the web re-boot's `bootSession` vs native's inline first boot) and
  documented.
- **build.zig's headless-exclusion contract is enforced at the
  generator**: `collectZigFiles` skips the whole `src/raylib/`
  directory, `native.zig`, and `web.zig` with comments naming the
  seam rule - the "test build must never link raylib" invariant is
  structural, not convention.
- **The generated files are gitignored build artifacts**, regenerated
  every build (ids, lookups, test root, assets map, sprite metadata)
  - committed drift is impossible by construction.

### Findings

None. This is the second zero-finding part (after Part 8) - the
composition layer's job is wiring, and the wiring all checks out
against DESIGN → Platform Seam's frame/driver split.

### Highlights

- **H-10.1 - `update()` as an annotated ordering.** The hardest thing
  about a composition root this size is remembering WHY the order is
  what it is; this file answers at every seam, including the subtle
  ones (the wait's interjection-drain assumption, the drag/release
  yield, the M2 consume rule's undo-while-focused behavior).
- **H-10.2 - The round-trip reconstruction test at the root.**
  Forward play == replay, proven by the real machinery, in the file
  that owns the frame - the single most load-bearing test in the
  suite, placed exactly where a regression's blast radius is most
  visible.
- **H-10.3 - build.zig as the machine-walked-truth pattern at build
  time.** Five generators (ids from directory scans, lookups, the
  test root, the assets map, sprite metadata from PNG IHDRs), each a
  named fn with a doc comment, each making a hand-maintained list
  structurally impossible. 981 lines that read as a toolbox, not a
  script.
- **H-10.4 - The StartupMemory tracked-teardown design.** A retain
  list of (bytes, sections) pairs + one free fn + leak-checked tests
  - the unglamorous machinery that makes the web re-boot safe, built
  as a first-class contract rather than an afterthought.
- **H-10.5 - The button payload relay's fail-fast check.** One line
  at the relay (a wrong variant PANICS, naming
  `types.actionButtonPayload`) is what converts the payload union
  from "silently eaten by `orelse return`" into "wrong wiring is a
  crash with a pointer to the fix" - the 28-line dispatch bug class
  killed by a seam, not by more code.
- **H-10.6 - The entries' discipline.** Both entry files import
  `raylib/backend.zig`, never raylib; both call the same
  `createSessionSetup` then hand off to `run`/`frame`; the platform
  differences are exactly the documented ones (driver shape, mount,
  watchdog, re-boot) and nothing else leaked across.

### Part verdict

The composition layer is the project's discipline in miniature:
large files that stay readable because every delegation carries its
rationale, invariants enforced at the generators rather than trusted
to convention, and the one test that matters most living at the top.
Zero findings - the wiring is exactly what DESIGN describes.

---

## Part 11 - Test suite (~19k lines; method note inside)

**Scope:** `test_harness.zig` (211) + the 14 dedicated tier files
(handler_tests_editor 8,764 / combat 1,047 / turnflow 940 / gear 827
/ ai 551 / autosave 436 / devtools / ui_surfaces, skill_tests 2,476,
input_tests_console 581 / escape 222, content_validation_tests,
test_ui_census, font_codepoints_tests) + the inline test blocks read
across Parts 2-10 (roughly half the suite's mass was read in full
inside its owning files - parser, loaders, writers, session_log,
session_log_bundle, game_zip, zip_reader, file_source, state, types,
functions, ai_movement, skill_helpers, input, keybind_edit,
dump_walker, view's census, session_setup, main's round-trip). The
dedicated files were verified at their tier conventions, coverage
claims, and assertion patterns; handler_tests_editor's 154 tests
were structure-mapped (its consumption switches mirror the
orchestrator arms verified in Parts 3/9).

### The project's coverage admissions verify PRECISELY

TODO's self-assessed gaps were each checked mechanically - and each
is exactly as claimed:

- **swap_hands: ZERO drain tests** (one comment mention only).
- **Cue-wiring assertions in the tier files: ZERO** - the single
  pinned choke-point test (the skip double-play guard) lives in
  input_handlers.zig where TODO says it does.
- **skill_tests.zig: pure contract only** (zero processEvent/runToIdle
  - 75 tests at the useSkill/aiOptions/getValidTargets level); the
  drain-coverage claim (adrenaline only) matches.
- **The exhaustive comptime session-log round-trip (the variant walk)
  is NOT present** - still open, as TODO tracks.

This matters beyond the gaps themselves: the project's test
self-assessment is TRUSTWORTHY. When TODO says a coverage hole
exists, it exists exactly as described - which makes its "done"
claims (verified throughout Parts 1-10) credible by symmetry.

### Assertion patterns, verified with honest caveats

- **The census discipline is real and evolving.** test_ui_census.zig
  is the hoisted exhaustiveness helper DESIGN prescribes:
  `expectContentReachable` builds the panel at EVERY scroll offset,
  asserts each window is an ordered subset of the semantic content
  list AND the union covers it completely - geometry as INPUT, never
  expectation, mismatches printing found-vs-expected. Adopted by
  editor_inspector (the file DESIGN named as the adopter); the
  per-file semantic-query helpers elsewhere (expectMenuButtonLabel
  etc.) are a different, legitimate class (queries, not window
  snapshots).
- **Hand-pinned numeric counts exist in volume** (123
  `expectEqual(@as(usize, N)` sites in ui/, 347 in the handler test
  files). Sampled judgment from the full reads: the large majority
  are CONSTRUCTED-FIXTURE contracts ("3 entities, kill 1, expect 2")
  - assertions of intended behavior, not derived-fact churn. The
  churn class (counts of things that grow by design) was found where
  TODO said it was fixed (the utility census) and not elsewhere in
  the sampled reads. The raw numbers are reported so the claim is
  checkable, not just asserted.
- **Awkward values are the norm**: tie chains broken to the final
  key, empty/null inputs, dead occupants, degenerate grids, hostile
  zips built by patching central records - the boundary-invisible
  cases DESIGN's pattern list demands.

### Findings

None new. The one structural observation (handler_tests_editor's
171 hand-written anytime-call sites) is TODO-tracked (the
pressEditorButton helper item) with an accurate description; the
zero new findings is consistent with the suite being the most
self-reviewed part of the project - its gaps are catalogued in TODO
with a reliability this part just verified.

### Highlights

- **H-11.1 - test_harness.zig teaches its own bug history.** The
  scratch persistent dir exists because a planted autosave broke the
  missing-autosave test on later runs (the comment says so);
  runToIdle's maybeRecordIdlePoint dedup documents the
  double-idle-point failure mode; openMiddlePanel routes through the
  real event path so fixtures pass the replay legality gates. A
  211-line file carrying three shipped-bug lessons by name.
- **H-11.2 - The census evolution follows DESIGN's prescription
  exactly.** The helper exists, it is the exhaustiveness shape
  (ordered-subset + full-coverage properties), it prints
  found-vs-expected, and adoption is spreading file-by-file as the
  doc anticipated - the anti-churn core landing in practice.
- **H-11.3 - skill_tests' contract density.** 75 tests over 44
  skills + the shared helper family: cast semantics, rating
  rationale, targeting edge cases, tie chains - one file a new skill
  author can read to learn both the interface AND the testing
  standard.
- **H-11.4 - Coverage honesty verified.** Every TODO test-gap claim
  checked out mechanically. The discipline of admitting gaps
  precisely (and fixing them where they bite, per the utility-census
  history) is why the suite can be trusted without a coverage tool.
- **H-11.5 - The suite as regression memory.** Across every part of
  this review, the pattern held: tests name the shipped defect they
  guard (the ctrl+S dead keybind, the skip double-play, the Enter
  dual-bind, the rollover swallow, the census churn, the planted
  autosave, the mangled settings, the ghost squares). 892 tests that
  double as the project's incident log.
- **H-11.6 - The harness smoke test pins shipped content.** "No
  key-validation warnings from shipped startup config" - the
  embedded files' cleanliness is itself a tested invariant, at the
  level every test inherits.

### Part verdict

The test suite practices what DESIGN → Testing preaches: tier
conventions hold, the assertion patterns hold where they matter
(with the raw count numbers reported for checkability), the census
helper is landing, and the coverage gaps are catalogued with a
precision this review verified rather than assumed. No new findings
- and given that this part's job was to audit the project's own
audit, that is the strongest possible result.

---

## Part 12 - Data, assets, scripts

**Scope:** `data/**` (campaign content, weapon types, defaults,
salvage, decorations, tips, themes), the license files, `.gitignore`,
the nine `scripts/`. Much of this part's verification already landed
in Part 0 (the report scripts regenerated byte-identical; test.sh
PASS; dash sweep clean) and Part 11 (the harness smoke test asserts
ZERO key-validation warnings from shipped startup config - which
means every shipped config file's keys are whitelist-clean, and the
campaign graph integrity checks that run at every load surface
nothing on the shipped campaign).

### Verified

- **All 14 shipped Layout-bearing files (levels + hubs) use the
  counted grammar** (`Layout N`) - no legacy bare-Layout files in
  shipped content; the editor-written and shipped shapes agree.
- **Every gear-stat value in shipped content sits at or under its
  bound** - and several sit deliberately AT the max (max_player.txt's
  loadout: damage 10, spell_damage 10, speed 2, pickup_radius 5 -
  every bound exercised by real content, so the clamp paths and the
  bound constants are pinned by the shipped data itself, not only by
  fixtures).
- **Per-type file_format_versions are consistent with the parser
  constants** (spot-checked across levels/hubs/missions/campaigns).
- **The scripts are a coherent toolkit**: each wraps exactly one
  concern with filtered, unambiguous output (test.sh's PASS/FAIL
  labeling, web.sh's emsdk-noise filter); the three report scripts
  delegate to Zig host tools that write whole files (the
  write-after-each-step sweep concern doesn't apply - they are not
  text-transform sweeps); doc_symbol_check and unused_pub_report ran
  clean in Part 0.
- **The licenses**: three content licenses + code MIT, all embedded
  into the exe by build.zig's `collectLicenseFiles` (verified in
  Part 10) - the single-file binary ships its attribution.

### Findings

None. (The .gitignore's stale comment hygiene was Part 1's n-1.5;
sound_report.md's tracking asymmetry was Part 1's m-1.2 - both
already recorded.)

### Highlights

- **H-12.1 - Shipped content is a tested invariant.** The harness
  smoke test asserting "no warnings from shipped startup config"
  pins grammar + key whitelists + (via the load path) campaign graph
  integrity for every embedded file, on every test run. Content
  drift breaks the build's own suite, not a player's session.
- **H-12.2 - The bounds are exercised by content, not just tests.**
  max_player.txt sits at every single max - the at-the-bound
  behavior a fixture would have to invent is the shipped default
  experience.
- **H-12.3 - Nine scripts, nine single concerns, zero overlap.** No
  script duplicates another's job; each is the filtered wrapper its
  AGENTS description claims (verified by running them, not reading
  them).

### Part verdict

The data layer is exactly what the machine-walked-truth philosophy
promises: content that validates itself through the normal load path
on every test run, bounds exercised by real content, and reports
that cannot lie. Nothing to find.

---

## Part 13 - Cross-cutting sweeps (whole tree)

The machine checks ran at review start (Part 0: tests, builds, web
runtime, dash sweep, doc-symbol check, unused-pub, report
regeneration); the per-part lenses accumulated the rest. This part
runs the remaining whole-tree greps and reconciles the totals.

### Sweep results

- **TODO/FIXME/HACK markers: ZERO violations.** The raw grep finds 6
  hits - every one is a comment POINTING AT TODO.md ("see TODO",
  "dims verification is a TODO"), which is the rule's own escape
  hatch working as designed ("if a gap is worth tracking, it lives in
  TODO.md"). Zero actual forward-tracking markers in code. The rule
  holds 100% across 108k lines.
- **Forward-looking prose: holds except the 2 known instances.** The
  remaining "when it lands" hits describe RUNTIME events (a marker
  landing at a frame boundary); "must revisit this bound"
  (font_codepoints) states a maintenance condition on a documented
  limit. The two genuine violations remain Part 2's
  `discovered_hubs` comments - the only TODO-prose-in-code found in
  the tree.
- **Naming conventions: CLEAN.** The `alloc` hits are std API method
  calls (`allocator.alloc`), not project abbreviations. Verbose
  naming held throughout all parts.
- **`///` inside function bodies: zero** (the naive grep matches
  legal struct-field docs; the compiling tree is the proof - Zig
  makes the violation a compile error).
- **Line length, quantified for TODO's undecided style item:**
  785 lines over 120 chars (0.7% of the tree), 267 over 140, 109
  over 160 (longest ~208, concentrated in handler_tests_editor and
  session_setup). With zig fmt not checking length and any
  retroactive wrap rotting immediately, the numbers support: **(a)
  drop the item, or (b) a going-forward wrap rule with no retro
  churn.** Option (c) ("fix only egregious >120") would be 785 lines
  of churn; if any action is wanted at all, the 109 lines over 160
  are the only defensible micro-target - and even those are better
  left to `zig fmt`'s future judgment than a one-off sweep.
- **`!replaying` gates as a set: audited in Part 6** (dead defense,
  keep + document at the choke point). **Float-in-gameplay: holds**
  (Parts 2/4). **`page_allocator`: holds outside the host tools**
  (Part 7).

### The "KNOWN DEFERRED BUGS: (none)" reconciliation

TODO claims no known deferred bugs. From the review's perspective
this claim was TRUE - every gap found was either already TODO-tracked
(and accurately: the Parts 6/7/8/9 confirmations) or NEW to this
review. The review ADDS six known items the project did not have:
m-2.1 (`write_fn(undefined)` - a latent UB fallback), m-3.1 (hub
move_player unvalidated at the replay seam), m-4.1 (the lingers
prepare landmine), m-5.1/m-5.2 (FileSource path normalization +
bundle size caps - anticipated by the design's server-seam framing
but not listed as tasks), m-7.1 (world-layer magenta gap), m-9.1
(mission-zip bomb caps). All six are recorded with dispositions in
this review and proposed for the TODO delta in Part 15.

### The unmeasured-items verdicts (collected)

| TODO item | Verdict |
|---|---|
| Stripe-scope-per-tile flushes | Fine at scale (~40 small flushes); two-pass restructure only if profiled |
| `sprite_bounds` per-frame rebuild | Fine (decode cached; small arena map) |
| Web frame-time dips | Measure-first stands; candidates identified |
| Mouse-owns-the-frame arrow-drop | Agree - wait for observed eaten taps |
| Lost mouse-up drag cancel | Tracked accurately; land with window-events work |
| Tooltip cross-axis clamp | Tracked accurately; rare degenerate case |
| Snapshot ring post-branch holes | The recorded decision is right - the quick fix would break FIFO |
| AI/eval worst case | Trivial at caps (~100k integer ops/enemy turn) |

### Findings

None new beyond the style-item quantification (which feeds TODO's
existing undecided item, not a new finding). The doc-drift class
closes at **18 located instances** across the tree (the running count
from Parts 2-7), plus the two DESIGN-level drifts (M-1.1 saturation,
m-7.1's DESIGN overgeneralization).

### Part verdict

The cross-cutting picture is remarkably clean: the convention rules
that matter (no markers, no forward prose, verbose naming, integer
gameplay, replay gates) all hold under whole-tree mechanical
checking, with the handful of exceptions already catalogued. The
project's "none currently" deferred-bugs claim was honest - this
review's six additions are the first entries it needs.

---

## Part 14 - The docs, second pass (code-informed)

Part 1 read the docs for internal consistency; the code parts
(2-13) read them as contracts. This pass closes the loop: what did
the code reading change about each doc's verdict?

### AGENTS.md - held up as working rules; one decision to add

Every working rule AGENTS states was verified IN PRACTICE across the
code parts, not just on paper: the config-layer OOM convention
(Part 5, all eleven files), the comment rules (Part 13's zero-marker
sweep), minimize-pub (Part 0's 0-dead report), the config grammar
(Part 5), the Zig gotchas (the labeled-block prong shape appears
throughout, correctly), the build/test workflow (Part 0), and the
doc lifecycle itself (Part 1). The code reading surfaces exactly ONE
addition AGENTS needs: **the fmt decision from M-0.1** - either
adopt `zig fmt --check` as a commit checkpoint or record "fmt is not
a gate" as policy. And optionally the comment-hygiene line suggested
in m-2.2 ("when moving/renaming a fn, its /// moves with it") - the
one-sentence version of the 18-instance lesson.

### DESIGN.md - two drifts to fix, otherwise verified true

The code parts verified DESIGN's claims subsystem by subsystem; the
verdict is extraordinary - of the hundreds of settled-design
statements checked as contracts (the purity gates, the legality
system, the zip policy, the camera math, the classification, the
frame/driver split, the pacing derivation, the census philosophy),
exactly TWO proved false at the code level:

1. **M-1.1**: Clones' "Material wallet ADDS clamp at u32 max" -
   present tense for an unimplemented guard (the code: plain `+=`).
2. **m-7.1's DESIGN side**: "MISSING art draws a magenta box" - true
   for the UI draw paths, false for the world draw paths (they draw
   nothing).

Both are one-line doc fixes (or one-line code fixes, which the
dispositions prefer). No DESIGN section was found describing
architecture that no longer exists; no "why X" rationale proved
wrong. For a 6,300-line design doc over 764 agent-driven commits,
two drifts is the number worth stating plainly.

### TODO.md - accurate on every claim checked; six additions proposed

Every TODO claim the review checked - coverage gaps, deferred
behaviors, open questions' descriptions, "DONE" code existing,
"open" code not existing - verified accurate (the Part 11
reconciliation being the strongest case: even its self-criticism is
precise). The review's six new items (Part 13's reconciliation)
plus the opinions it formed for TODO's own undecided items (the
style item's numbers, the marquee surface-don't-block
recommendation, the mission-import cap fix) are proposed as a TODO
delta in Part 15.

### DONE.md - archiving verdict

Read as history throughout (the bug stories cited in nearly every
part's tests-and-comments findings matched the entries they named),
the skim's Part 1 verdict stands informed by everything since: **the
format serves its purpose; the ONE improvement worth making is a
machine-generated `##`-header index at the top** (267 headers is
past scroll-navigation; an index derived from the headers cannot
drift - the project's own pattern). The two coexisting archival
shapes (legacy mega-sections vs flat per-slice entries) are
harmless; flattening them would be churn on a history file. The
18.5k-line size is sustainable until the divided-format question
TODO already tracks becomes pressing.

### README - verdict unchanged

Accurate as a quickstart; the "early stages" line undersells
(Part 1's n-1.6) - a demo-milestone rewrite item, correctly already
riding the rename milestone in TODO.

### The lifecycle, judged end-to-end

The four-doc lifecycle is not just documented - it is the reason
this review was possible at this fidelity. A fact lived in one place
in every case the review checked; open questions were visibly open;
settled design was findable by section; history was never consulted
as current truth (and never needed to be). The two DESIGN drifts
found are exactly the class the lifecycle guards against -
present-tense leaks of unlanded design - caught here only because
the review read both directions. **The single highest-leverage
maintenance habit this review can recommend: keep the DESIGN present
tense honest at landing time** - when a design section describes a
guard/feature that isn't implemented yet, mark it "(planned - see
TODO)" at the paragraph, the way the Post-game section already does
by context.

### Findings

None new - this pass consolidates. Running doc-drift inventory for
the cleanup pass: 2 DESIGN-level (M-1.1, m-7.1's doc side), 18
comment-level instances (Parts 2-7), the fmt-gate decision (M-0.1),
AGENTS' optional comment-hygiene line.

---

## Part 15 - Synthesis

### The issue register (deduplicated, by severity)

**Critical: none.** No player-visible bug, data-loss path, or broken
core invariant was found in 108k lines. The replay/determinism
guarantee - the architecture's foundation - survived every attack
this review mounted against it (Parts 2, 3, 4, 6, 11).

**Major (1):**

1. **M-1.1 - DESIGN → Clones claims a saturation guard the code does
   not implement.** `Materials.add` is plain `+=` at all three add
   sites; in a ReleaseFast build a crafted farm mission silently
   wraps wealth (in safe builds it panics - acceptable). Fix either
   way: the three-line saturating add (TODO already notes it "could
   land early") or the one-line doc fix. Prefer the code.

**Minor (13 distinct, after folding the drift class):**

2. **The doc-comment drift class - ~18 orphaned/duplicated/stale
   `///` locations across 10 files**, two with real teaching power:
   input.zig's `InputState` "lives on GameState" (backwards - the
   replay architecture depends on SessionState) and the three skills'
   rating-doc numbers disagreeing with their own code. One cleanup
   pass + optionally a one-line AGENTS habit note.
3. **M-0.1 - `zig fmt --check` fails on 10 files; no fmt policy
   exists anywhere.** Decide: adopt as commit checkpoint (fix is one
   command) or record not-a-gate.
4. **m-2.1 - `markWriteDirty`'s overflow fallback calls
   `write_fn(undefined)`** - UB where a panic belongs. One line.
5. **m-2.3 - `PlayerData.discovered_hubs: []const Hub`** stores full
   hub structs for a name set (+ the tree's only two comment-rule
   violations). Re-type to names BEFORE campaign-editor slice 2.
6. **m-3.1 - hub `move_player` unvalidated at the replay seam**
   (level moves get full BFS anti-cheat; hub moves none). Small
   consistency gap; land before the server seam.
7. **m-4.1 - `that_which_lingers.playerPrepareSkill` returns a
   `create_effect`** - dead today (non-targeting skills never
   prepare) but armed: any future caller double-applies a
   stacking-duration effect. One line: `return null`.
8. **m-5.1 - FileSource has no path normalization** - crafted
   bundles can seed reconstruction reads outside the persistent
   dir. A ~15-line `validateRelativePath` gate at the seam.
9. **m-5.2 - `loadSessionLogBundle` lacks a total-bytes cap.**
10. **m-7.1 - world-layer missing art draws nothing, not the
   documented magenta** (UI paths draw magenta correctly). Two-line
   fix or a DESIGN split statement.
11. **m-9.1 - the mission-zip import lacks the game import's bomb
    caps** (full extraction before any size check; Minor today,
    Major at the online-services milestone). ~15 lines mirroring
    game_zip's headers-first pass.
12. **m-1.2 - the three sibling reports are tracked inconsistently
    by git** (sound_report.md ignored, its siblings committed).
13. **m-1.3 - DESIGN.md (405 KB) has no index**; a generated header
    index is ~30 lines of non-drifting navigation.
14. **m-1.4 - AGENTS.md at 822 lines is at the edge of its
    session-start job** - case-study prose that belongs in DONE.

**Nits (11):** gitignore comment hygiene; README "early stages";
`validateSkillTarget`'s discarded params; the stranded
`save_files_last_scan_us`; `getPlayerEntity`'s ignored hub
parameter; the tile-set construction duplicated 4×; the settings
key-map's borrowed `level_metadata_keys` name; the drag-threshold
compare duplicated 6×; menus.zig's five-surface file;
editor_inspector's growth (census-gated per TODO); the world
`orelse return` shape (folds into m-7.1).

### The highlight register (the things to protect)

The full 67 live in their parts; the top of the register, ranked by
how much they explain this codebase's quality:

1. **The purity discipline, verified at the line level** (Parts 3,
   4) - every side effect gated, every handler a pure transform.
   The foundation everything else stands on, maintained the hard way.
2. **The two-gate replay legality system** (Part 2) - the
   type-as-whitelist, the per-arm context checks, the surface-supply
   gate; anti-cheat-grade design that survived adversarial reading.
3. **The machine-walked-truth discipline, everywhere** (Parts 0, 5,
   10, 12) - five build-time generators, three regenerable reports,
   bidirectional comptime lockstep guards, shipped-content-as-tested-
   invariant. Hand-maintained duplicates of derivable facts are
   structurally impossible in domain after domain.
4. **The documentation lifecycle actually working** (Parts 1, 14) -
   two DESIGN drifts in 6,300 lines over 764 commits; TODO's
   self-assessment verifying precisely (Part 11); the four-file
   system as the reason a review this fidelity was possible.
5. **The suite as regression memory** (all parts) - 892 tests that
   name the shipped defect each guards; the harness teaching its own
   bug history; the census helper landing as prescribed.
6. **`deep_copy.zig` making unsupported shapes compile errors**
   (Part 2) - the type system as the determinism guarantee's
   guarantor.
7. **The four-pass hostile-zip import** (Part 5) - validate-everything-
   then-stream, with tests that construct the exact hostile shapes.
8. **The EvalFrame** (Part 4) - 25 lines replacing five structural
   rules with one mechanism.
9. **`end_level`** (Part 3) - three exit regimes + the harvest
   choreography, every LIFO trap documented at its site.
10. **`update()` as annotated ordering** (Part 10) - a composition
    root that answers "why is this here" at every seam.
11. **The UI state classification holding under machine
    verification** (Part 8) - a discipline-only rule, zero
    violations in 145 files.
12. **The lockstep comptime guards at the platform seam** (Part 7).

### Overall assessment

**Architecture: exceptional.** The Elm-like core, the event-stack
orthogonality, the state classification, and the replay-first design
are not just present - they are enforced (by the type system, by
comptime guards, by machine-checked reports, by tests that pin the
enforcement itself). The review repeatedly tried to find ways around
the invariants and could not.

**Where the 109k lines feel earned vs accreted:** earned, almost
entirely. The density of documented invariants per line is the
highest I have seen in a project of this age. The accretion spots
are exactly the ones the project has already catalogued: the editor
test boilerplate, the biggest files' optional splits, DONE.md's
size - all tracked, all correctly deprioritized.

**The defect profile:** zero critical, one major (a doc lie, not a
code break), and a long tail of comment-hygiene and hardening items.
The recurring class - stale prose left behind by refactors - matters
precisely because the prose is otherwise good enough to be trusted.
The code defects found (m-2.1, m-4.1, m-9.1, m-7.1) share a shape:
small, latent, sitting at seams where the surrounding quality is so
high that the gap never surfaced in play.

### Security-posture verdict

**The untrusted-input panic map:** crafted logs cannot seed
machinery events (two-gate system, Part 2); orchestrator payloads
are bounds-checked against live state; hostile numeric tokens fail
as null/error at every parser site; zips are zip-slip-clean with
caps at the game-import seam. **The residual exposure, all
catalogued:** the FileSource traversal read (m-5.1), the mission-zip
bomb (m-9.1), the bundle caps (m-5.2), the material-overflow family
(M-1.1), and the hub-move gap (m-3.1).

**The recommendation that matters most: the future
server-revalidation build must be a SAFE-MODE build (ReleaseSafe
minimum).** The entire validation machinery is panic-based - the
force-unwraps, the cache-miss panics, the verifyReplayMatch panics -
and in ReleaseFast those become UB instead of fail-fast. One line in
the online-services design doc when that session comes.

**Verdict on the posture for the server seam: the fail-fast design
holds, but only after a small hardening pass** - the six-item list
above (m-5.1, m-5.2, m-9.1, M-1.1's code side, m-3.1, the safe-mode
policy line), all small, all pointed, all landing naturally with the
online-services work the project already plans. The deeper
validation architecture (checking mode, derived turns, the legality
gates as the server's own primitives) is already built and tested -
the project is closer to server validation than its TODO suggests.

### Performance verdict

**The reasoned cost map:** view() rebuild per frame (by design, the
per-frame arena absorbing it); the drain+view+render frame shape on
turn steps (the web dips' candidate); deepCopy/snapshots at idle
points (bounded by the ring, compacted arena); AI evaluation trivial
at caps (~100k integer ops per enemy turn, memoized); stripe scopes
and sprite_bounds fine (Parts 7's verdicts); the memory model's caps
still estimates (TODO's measurement task, correctly tracked).

**The two or three things worth profiling first:** (1) the web
frame-time dips while holding space - a devtools Performance capture
splitting drain vs view vs render (TODO already plans exactly this);
(2) view()'s per-frame allocation profile at max caps (10k tiles +
256 entities through the frame arena); (3) a deepCopy timing at the
snapshot ring's capacity on a max-size level, feeding the caps
tuning. No profiling is warranted before those three; nothing else
showed up as a candidate.

### Recommended next work (from review findings only)

1. **The hardening pass** (the six-item server-seam list + m-2.1 +
   m-4.1's one-liners) - one focused session, ~100 lines total, each
   item independently testable.
2. **The hygiene pass** (the 18-location comment cleanup + the fmt
   decision + the two DESIGN one-liners) - one session, zero risk.
3. **The campaign editor, with two review riders**: re-type
   `discovered_hubs` to names before slice 2 (m-2.3), and settle the
   `start_hub` path shape (the `data/campaigns/...` vs
   `campaigns/...` convention noted in Part 5) in slice 2's design.

### Proposed TODO.md delta (never applied without your sign-off)

**Add (bugs/hardening):**
- Saturating `Materials.add` (three sites; DESIGN line updates with
  it) - the M-1.1 fix
- Mission-zip import: headers-first caps mirroring `importGameFolder`
- FileSource: `validateRelativePath` gate at readFile/writeFile
- Session-log bundle loader: total-bytes cap
- World draw paths: magenta fallback (or DESIGN split statement)
- Hub `move_player`: legality arm at the replay seam
- `markWriteDirty` overflow fallback: `@panic` instead of
  `write_fn(undefined)`
- `that_which_lingers.playerPrepareSkill`: return null
- Record: server-revalidation builds MUST be safe-mode (ReleaseSafe+)

**Add (hygiene):**
- One comment-drift cleanup pass (~18 catalogued locations; the
  semantically-misleading two first)
- The fmt decision (adopt `zig fmt --check` at commit or record
  not-a-gate)
- Optional AGENTS line: "when moving/renaming a fn, its /// moves
  with it"

**Settle (numbers/opinions provided):**
- The style-wrap item: 785 lines >120 / 109 >160 quantified;
  recommend drop or going-forward-only
- The marquee-marker trap: surface-the-loss in the drag preview,
  when it bites
- `discovered_hubs` re-type: before campaign-editor slice 2

**Optional polish (nits, no urgency):** the DONE header index, the
DESIGN section index, the settings key-map naming, the menus.zig
split, the small dedup helpers (tile-set ×4, threshold ×6).

---

## Closing

This review read every tracked file in the repository (DONE.md
skimmed as declared), verified every load-bearing invariant the
project's own docs claim, attacked the determinism guarantee from
five directions, and audited the project's self-audit. The result:
**zero critical defects, one doc-level major, a hardening list that
fits in one session, and a highlight register that explains why this
codebase is as reliable as its test suite claims.** The project's
documentation system, its machine-walked-truth discipline, and its
purity-enforced architecture are the three assets to protect above
all others - they are why 109k lines of agent-written code can carry
this level of review confidence at all.

*Review complete. All 15 parts delivered. Nothing in the tree was
modified; every disposition above awaits your decision.*
