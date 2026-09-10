# Magic Camera — working rules

A LiDAR scanner for iPhone/iPad Pro that hands back a finished model, not a
point cloud and a homework assignment. Swift 6 (strict concurrency), SwiftUI,
ARKit scene depth, Metal, SceneKit/RealityKit, ModelIO, FoundationModels.
**Reply to the owner in Czech.** Source literals are English and *are* the
localisation keys; `cs.lproj` translates them — see §2.

This file is the operating manual. It is short on purpose: every line was paid
for by a round, and each one saves a build. Builds here cost ten minutes.

---

## 0. What these documents are for, and what they are not

**They are not an alibi.** "It was in the rules" closes nothing. A rule that
lives only in prose has already failed twice here: the louver regulariser
shipped in r54, was disabled in r56 for false-firing on the marching-cubes
lattice, and was still in the tree in r87 — three rounds of a comment saying
"this is wrong" instead of a test saying so.

The standing obligation:

**Where a rule can be enforced by a test, a script or a type, that is where it
belongs. Prose is the fallback for what cannot be, and every prose-only rule is
a backlog item, not a finished job.**

Already mechanical — these cannot be broken quietly:

| Rule | Enforced by |
|---|---|
| No single confidence signal can reject a depth sample | `DepthSampleConfidenceTests.testNoSingleSignalCanRejectASample` — rejection needs several signals to agree |
| A zero frame grade cannot reject a perfect sample | `DepthSampleConfidenceTests.testAZeroFrameGradeCannotRejectAPerfectSample` |
| Sample grading is on for every shipped capture profile | `DepthSampleConfidenceTests.testGradingIsOnByDefaultForEveryShippedCaptureProfile` |
| The GPU kernel carries the same grading constants as Swift | `DepthSampleConfidenceTests.testGpuGradingCarriesTheSwiftConstants` |
| ICP drag is measured **at the data**, not at the world origin | `FrameToModelICPTests.testDragIsMeasuredAtTheDataNotTheWorldOrigin` — the r60 lever-arm fix |
| Levelling removes tilt, keeps yaw, and stops tilt compounding | `FrameToModelICPTests.testLevellingStopsTiltCompounding` — the r88 2.78° floor |
| The bake triangle budget is derived from the atlas pages, never fixed | `BakeTriangleBudgetTests` — including the device room that came out mush |
| A small subject is never decimated by the budget rule | `BakeTriangleBudgetTests.testASmallSubjectIsNeverDecimatedByThisRule` |
| The unreliable-point bar is the grading's own doubtful mark, not a higher one | `UnreliablePointBarTests` — a bad scan is thinned, never gutted |
| A surface mask that would gut the cloud refuses instead | `SurfaceMaskTests.testMaskReturnsNilWhenItWouldGutTheCloud` |
| The room lattice keeps its device-measured noise floor; Object never inherits it | `CaptureQualityTests.testSmallRoomHoldsTheNoiseFloor`, `…testObjectKeepsFineLatticeWithoutFloor` (in `QualityAndDensityTests.swift`) |
| Autosave writes stay a small multiple of the final cloud | `ScanAutoSaveTests.testTotalWritesAreBoundedByASmallMultipleOfTheFinalCloud` |
| A review operation completes **exactly once**, cancelled or superseded | `OperationRunnerTests` (9 cases) |
| The recipe's canonical order covers every step exactly once | `ScanRecipeTests.testCanonicalOrderCoversEveryStepExactlyOnce` |
| The Model recipe always isolates; the Surface recipe never does | `ScanRecipeTests` |
| A scan measures itself and says what it is | `ScanMetricsTests` — footprint ignores the air above a table |
| Every localisation key has a non-empty Czech translation, format specifiers intact | `LocalizationTests` (5 cases) |
| Guidance never publishes on one bad frame | `CaptureGuidanceTests.testOneBadFrameNeverShows` |
| Every decision rule — `static func` **and** `static var` — in a policy-bearing file is named in `docs/CODEMAPS/policy.md` | `make verify-docs` |
| Every FMEA `Where` cell resolves to a real file | `make verify-docs` |
| Every breadcrumb kind the code emits is named in `docs/CODEMAPS/diagnostics.md`, and a crumb whose kind cannot be read from its literal is allowlisted **with a reason** | `make verify-docs` |
| No document links to a file that is gone | `make verify-docs` |
| Every test class, case and case count the live documents cite exists in `Tests/` | `make verify-docs` |
| All five of the above run on every pull request | `.github/workflows/ci.yml` → the `docs` job |

Still prose-only, so still breakable — **if you touch one of these, ask whether
the fix is a test rather than a paragraph**:

* **The memory governor.** The r88 room path peaked at 3144 MB with 231 MB of
  headroom and four `memory pressure — critical` events. It survived. Nothing
  stops the next one.
* **Isolation's floor.** `max(800, working.count / 20)` passed the r88 lamp by
  237 points and handed the reconstruction a pancake. The planar gate now stops
  the *consequence*; the fragment still gets through.
* **Breadcrumb fields reaching the export.** A field the builder does not name
  is invisible, and the code that emits it looks correct.

---

## 1. Build discipline — read before running anything

**Builds take ten minutes or more. Batch every edit and build once, at the end.**
Run them backgrounded; do not sit on a foreground build.

```bash
make generate     # xcodegen — after adding or removing ANY file
make build        # the whole thing, once, at the end
make test         # only when asked for it
```

1. `xcodegen generate` after adding or removing a file. The project is generated
   from `project.yml` but `MagicCamera.xcodeproj` is committed, so a forgotten
   regenerate ships a target that does not contain your file.
2. **This host cannot build the app at all as of 2026-09-10.** `xcrun simctl
   list runtimes` is empty. `make build` dies with `error: Unable to find a
   device matching the provided destination specifier` — the `iPhone 17` device
   is still listed but was created against the iOS 26.3 runtime and Xcode here
   is 26.2, so it reports `runtime profile not found`. `make build-device` does
   **not** rescue you: `actool` needs a simulator runtime too and fails with
   `No available simulator runtimes for platform iphonesimulator`. The fix is
   `xcodebuild -downloadPlatform iOS`, which wants roughly 10 GB and this host
   had 11 GB free. **Until that runtime is installed, `make verify-docs` is the
   only mechanical check available** — it needs neither Xcode nor the network.
3. **Verify with `build`, not `test`.** Do not run `xcodebuild test` unless the
   owner asks. The scan pipeline is hardware-bound; the suite proves the value
   math, not the app.
4. **Counting failures: `grep "' failed ("`.** XCTest's trailing tally counts
   *assertions*, not tests, and reading it invented a "4 → 22 regression" that
   never happened (r74). The suite floor is **zero failures** as of r87 — any
   failure is new.

**Debug is compiled `-O` on purpose** (`project.yml`). `-Onone` makes the scan
hot loops 10–30× slower — a 1 M-point bilateral denoise goes 1.8 s → 55 s, which
trips the 90 s CPU watchdog on code that ships fine. `assert()` is compiled out
and lldb stepping degrades; that is the accepted trade. Do not "fix" it.

**Do not add Xcode run-script phases.** `ENABLE_USER_SCRIPT_SANDBOXING: YES` —
the sandbox denies reading `.git`. Anything needing the repo or the network
goes in the `Makefile`.

**The working directory flaps between worktrees.** This repo has several under
`.claude/worktrees/`, and the shell's cwd has silently switched mid-session.
**Always `git -C <absolute path>`**, and verify the commit's file list after.
**`main` is the trunk again as of 2026-09-10.** It had been sitting on
`c096dac` plus an empty merge commit while 67 commits of r60–r89 work lived
only on `claude/cloud-mesh-postprocess-optimize-8cb455`; that branch is merged
into `main` at `1b3a132` and both refs are pushed. Work on `main`, and prune a
worktree once its branch is in.

---

## 2. Failure signatures, in the order they actually happen

**Type-checker / stack overflow on a huge view.** `SpatialScanView.swift` (1022
lines) has crashed Swift's type-metadata instantiation through the sheer depth
of its tools tree. The diagnostic names `body`, never your lines. Extend it by
extracting a **nominal** sub-`View` — not another modifier, not another builder
closure.

**`EXC_BAD_ACCESS` in `objc_autoreleasePoolPop` on a cooperative thread** =
ModelIO over-release. `imageFromTexture` returns unretained; `takeRetainedValue`
on it double-frees. Wrap every off-main ModelIO block in `autoreleasepool`.

**Crash inside a `DispatchSource.setEventHandler`** = the Swift 6 MainActor/GCD
closure trap. The handler must be `@Sendable` and must not capture main-actor
state. Device crash logs: `~/Library/Developer/Xcode/DeviceLogs`.

**A connectivity pass finds no neighbours on a saved or exported mesh.** Textured
saves and USDZ are **duplicated-corner soup** — every triangle owns its own
vertices. **Weld before any connectivity operation** (hole fill, component trim,
smoothing, planar fit).

**AR Quick Look rejects an exported USDZ.** Untextured mesh USDZ must be written
with `SCNScene.write`. ModelIO's USDZ writer produces a file Quick Look refuses.

**Reading a USDZ from the command line** — two traps, half an hour each:
`SCNGeometryElement.primitiveCount` disagrees with the buffer on a baked soup
(derive the index count from `data.count / bytesPerIndex`), and `SIMD3<Float>`
has a **16-byte stride**, so writing `[SIMD3<Float>]` raw and reading it as
packed 12-byte triples shears the axes apart. The giveaway is a bounding box
identical on all three axes. Flatten to `[Float]` first.

**A Point/Mesh scan-kind picker in a build you are looking at is a *stale
build*, not a regression.** Mesh mode was removed by design in `8e60f50`;
`ScanKind` still exists internally.

**`Text("a" + "b")` is never translatable.** SwiftUI keys a `Text` on its
*literal*, so a concatenation produces no key and silently ships English.
`LocalizationTests` guards the table, not the call sites. Roughly 62 `showToast`
strings are still English — that is known, not new.

**Never anchor an `Edit` on a Swift `func` / `var` line.** Attributes
(`@available`, `@ViewBuilder`, `nonisolated`) sit above it and the insertion
steals them. Anchor on the `// MARK:` or the doc comment.

**Do not use `sed` to change a Swift argument list.** A label occurs in the call
you mean *and* in the initialiser you don't.

---

## 3. Evidence: measure the artefact, not the code

**Every fix on this branch that held up started from a number taken off the
owner's own scan files or the diagnostics export. Every fix that had to be
reverted started from reading the code.** When the owner reports something, the
first move is to get the scan file.

The channel is the device — iPhone 17,1, iOS 26.5 — and two artefacts:
**Settings ▸ Diagnostics** exports the breadcrumb log plus MetricKit crash/CPU
reports, and the scan itself saves as `.mcscan` / PLY / USDZ.

Read a diagnostics export in this order:

1. `scan config` — which knobs this scan actually ran with.
2. `scan quality — raw A → kept B` — what the filters took. A filter taking more
   than a third of the cloud is the finding.
3. `scan icp — … tilt N°` and `… drag` — registration health.
4. `surface cleanup`, `surface holes`, `texture-bake … repaired N/M` against
   `bake budget — … pages ≤ P`.
5. `memory pressure` events and the peak.

The four measurements that work, from r88 — repeat them rather than reinventing:

* **Lattice quantisation.** Fraction of points sitting exactly on a `k × voxel`
  lattice (`|p/cell − round(p/cell)| < 1e-3` on all three axes). Healthy ≈ 0%.
  A low fraction does **not** clear the mechanism: `snapped` counts intent at
  capture and fusion averages snapped points back off the lattice.
* **Floor: plane or slab?** Robust floor fit, then per-10 cm-tile height spread.
  Fit each quadrant separately too — a *constant* tilt is one bad rotation, a
  *varying* one is drift accumulated during the sweep.
* **Did a step delete something?** Height-profile the cloud and the delivered
  mesh identically and compare the same band. That turns "why did my table
  vanish" into "which step between these two files removes points".
* **Is a model flat?** Cluster triangles by (normal, offset), sum area per
  plane. 99.8% of area in one plane and a 1 mm bbox axis is not a lamp.

**Ship the breadcrumb with the fix.** The export is the owner's only channel, so
a change that cannot be seen in one is a change that cannot be verified. If
answering a question needed anything other than the export — a pasted console
log, a question to the owner, two crumbs joined by timestamp — **the export is
missing a field; add it in the same commit.**

**Write down what the export still cannot answer**, in
`docs/CODEMAPS/diagnostics.md`. An entry costs a line; rediscovering it costs a
round.

---

## 4. Design rules this codebase enforces

**A rule inside a view model is a rule with no test.** Pull the decision out to
a `nonisolated static func` over its inputs. `DepthSampleConfidence.grade`,
`CaptureGuidance.hint`, `FrameToModelICP.tilt`, `PhotoTextureBaker.affordableTriangleBudget`,
`SpatialScanViewModel.unreliableBar` and `ScanRecipe.standard` are the worked
examples, and `docs/CODEMAPS/policy.md` is the index of all of them. **If you
are about to add an `if` to a view model, the answer is nearly always a new row
in that table.**

**Every knob lives in `ScanConfig` with the reason it has that value.** Read the
comment before changing a number — most of them name the device scan that set
it. A knob only reaches the UI by earning it: it must change something the user
can see and name.

**Refuse rather than ship something plausible.** A model that is quietly wrong
is worse than one that is visibly incomplete. A step that would delete the
owner's furniture, flatten their subject, or synthesise most of a texture must
stop and say so. `SurfaceMask.maskToSurface` returning nil rather than gutting
the cloud is the pattern.

**Automatic loses to manual on scope.** When an automatic step and a manual one
disagree about what to touch, the automatic one is the safe default and gives
way. `userIsolated` means the owner picked it — build verbatim from their
selection.

**Every GPU path has a CPU fallback, and the signed field is CPU-spot-checked
before use.** GPU failures degrade; they never corrupt.

**Review-time work goes through `runOperation`** — `beginOperation` /
`endOperation`, a cancellable `Task.detached`, and the `workGeneration`
stale-guard. Anything else leaks a spinner or lands a superseded result.

**Cancel heavy work when the app backgrounds.** The "failed to terminate"
watchdog is caused by review-time reconstruction and bake surviving into the
background — `SpatialScanView.handleEnterBackground`.

**Ask the data before writing the fix.** Findings here have been diagnosed wrong
before being diagnosed right. One measurement usually settles it.

---

## 5. Reading protocol — before writing anything

Sessions that skipped this have re-implemented shipped features and re-diagnosed
solved findings. The roadmap once carried eight already-shipped items on its
front page.

### At the start of a session

0. **`docs/CODEMAPS/README.md`** — the routing table. One row per thing you
   might be about to do, and the one file to open for it.
1. **This file.**
2. **`docs/FMEA.md`** — symptom → cause → where. **Read the relevant section
   before forming a theory about any failure.** Build → §A. Odd scan or export
   → §B. Memory or performance → §C. About to write code → §D. About to trust a
   document → §E.
3. **`docs/analysis/README.md`** — which of the ~20 analysis documents are live
   and which are dated records. Four are live: `VISION.md` (whether to build
   it), `07-roadmap.md` (what to build next), the newest `HANDOFF-rNN.md`
   (what is going on right now — currently `HANDOFF-r89.md`), and
   `DEVICE-ROUND-r89.md` (what to do when you next have the phone).

### Before touching code, read the map for what you are touching

| Task | Read |
|---|---|
| anything, first time | `docs/CODEMAPS/architecture.md` |
| capture, reconstruction, texture, export | `docs/CODEMAPS/scan-pipeline.md` |
| **changing behaviour** | `docs/CODEMAPS/policy.md` — every tested rule, by name |
| a breadcrumb or a diagnostics export | `docs/CODEMAPS/diagnostics.md` |
| any SwiftUI screen | `docs/CODEMAPS/surfaces.md` — including the type-checker landmine |
| a tuning constant | `docs/analysis/SCAN-TUNING.md`, then the comment in `ScanConfig.swift` |

### Documents that will mislead you

* **`docs/ARCHITECTURE.md`** is the original two-mode sketch. Its shape is right
  and its inventory is dated — it still describes a Mesh scan kind that was
  removed.
* **The dated handoffs** (`HANDOFF.md`, `NEXT-CHAT.md`, `HANDOFF-r74/77/86.md`,
  `r71-device-round.md`, `handoff-multipage-atlas.md`) are history. The
  reasoning in them is often the only record of why a constant has its value.
  **Do not plan from them.**
* **Any number quoted in prose** was true the day it was written.
* **Any commit message.** Check the diff.

---

## 6. Documentation is part of the change, not after it

**A change that is not in the documents is a change the next session will undo.**

| Touched | Also update | Enforced |
|---|---|---|
| a decision rule (a `static func` or `static var` in a policy file) | `docs/CODEMAPS/policy.md` | ✅ `make verify-docs` |
| anything with a new failure mode | `docs/FMEA.md`, including its `Where` cell | ✅ the cell must resolve |
| a breadcrumb kind | `docs/CODEMAPS/diagnostics.md` | ✅ every emitted kind must be named |
| a test the documents name, or its case count | the citation, in `CLAUDE.md` / `docs/CODEMAPS/` / `docs/FMEA.md` | ✅ the class, the case and the count must exist |
| the shape of the docs directory | every link to it | ✅ |
| a tuning constant | the comment above it **and** `docs/analysis/SCAN-TUNING.md` | ❌ prose |
| state — what shipped, what the last export proved | a new `docs/analysis/HANDOFF-rNN.md` + `docs/analysis/README.md` | ❌ prose |

```bash
make verify-docs   # no network, no Xcode, run it before every commit
```

CI runs the same script on every pull request (the `docs` job, Linux, no Xcode),
so a document that drifts fails the PR rather than the next session. Running it
locally first is still cheaper than a red PR. **`docs/analysis/` is exempt from
the test-citation rule** — those are dated records, and a handoff naming a test
that has since been renamed is history, not a broken document.

**The rule that keeps the map true:** a status claim belongs in exactly one of
the three live documents. Everywhere else, write what the code *does*, not what
is *left to do* — a "still open" line in a reference document is a line nobody
will delete when it closes.

**When a round ends:** write `docs/analysis/HANDOFF-rNN.md` with what was
measured, what was fixed, what is **still unverified in the next export**, and
what was deliberately left open; add its row to `docs/analysis/README.md`; run
`make verify-docs`; commit documents *with* the code.

---

## 7. Commits

Conventional commits (`feat|fix|refactor|docs|test|chore|perf|ci`). **No
`Co-Authored-By` trailer** — attribution is disabled globally and the history
has none.

Messages here carry the reasoning, not a file list: what was believed, what the
evidence said, and what was deliberately *not* done. Scope them like the
existing history — `fix(scan): …`, `feat(bake): …`.

Stage explicit paths. Commit only after the build that proves the code, or say
plainly in the message that it is unproven — several commits on this branch are
honestly labelled "built, not yet activated" and "not device-verified", and that
is the standard.
