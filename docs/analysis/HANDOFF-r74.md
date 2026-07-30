# HANDOFF → r74

_Written 2026-07-30 at the end of r73. Self-contained: read this, then
[NEXT-CHAT.md](NEXT-CHAT.md) §5a for the r73 measurements. You do not need the
older docs to start._

---

## 0. Where the code is

| | |
|---|---|
| **Branch** | `claude/cloud-mesh-postprocess-optimize-8cb455` |
| **Worktree** | `/Users/keks/Developer/Magic-camera/.claude/worktrees/cloud-mesh-postprocess-optimize-8cb455` |
| **HEAD** | `aa4b80e` (pushed) |
| **`main`** | 180+ commits stale. **Never build it.** |

⚠️ The shell's cwd flaps between the main repo and the worktree mid-session. Use
`git -C "$W"` with an absolute `$W` for **every** git command, `-project <abs>`
for xcodebuild, and verify a commit landed with
`git -C "$W" show --stat --format="" HEAD` — the *file list* is what catches a
commit that went to the wrong tree.

`xcodegen generate` **from inside the worktree** after adding/removing files.
Do NOT use `xcodegen generate --project <path> --spec <path>` — it produced a
project whose bridging header crashed swift-frontend.

**When `xcodebuild` exits 139 after three lines of output**, or `simctl list
devices` returns nothing, the Xcode services are wedged, not your code:

```bash
killall -9 XCBBuildService com.apple.CoreSimulator.CoreSimulatorService xcodebuild; pkill -9 -f SourceKitService
```

Batch edits, build once at the end — the user's machine is slow.

---

## 1. State: this is a working app with no known ship-blocking code

Tier 0, Tier 1 (1.1–1.5), Tier 2 (2.1–2.8) and Tier 3.1 are **done**. Tier 4.2
(photogrammetry where LiDAR is weak) and 4.4 (Control Widget) are done too.

**Device-confirmed on 2026-07-30** — do not re-litigate these:

| | evidence |
|---|---|
| Bake no longer OOM-killed | ends at 1353 / 1749 MB; was pinning at 2700 against a 3375 MB limit |
| Multi-page atlas live | big room **2.63 → 1.35 mm/texel**; smaller rooms 0.63 / 0.79 |
| USDZ ships JPEG | `atlas_0.jpg` + `atlas_1.jpg` inside, **23.6 MB vs 94.5 MB**, AR Quick Look textures it |
| Room lattice consistent | every room `bound by noise-floor · cell 28 mm` at res 195 / 131 / 113 |
| Funnels work | located the thin-structure stage on their first run |
| `support check` works | correctly trusted a lamp the absolute bar alone would have failed |

---

## 2. Recommended order for r74

### 2.1 FIRST — resolve the test suite (4 → 22 failures, still unexplained)

Highest priority not because it is the biggest bug but because **it is the only
unknown**. Everything else on this list is a known quantity; this could be
nothing or could be four real regressions, and there is no way to tell without
looking. It has been deferred twice.

Baseline was 283 tests / 4 failures (`OrbitCoverageTracker` ×2, `MarchingCubes`,
`VisionGeometry` — x86_64 simulator float artefacts, verified against parent
`a598fb6`). A full run at r71 reported **288 / 22**. r71's own new tests were
individually confirmed green, so ~18 failures are unaccounted for.

They were never identified: the run was captured through too narrow a grep
(`^Test Case` misses xcodebuild's timestamped lines) and every re-run died with
CoreSimulator wedged.

```bash
xcodebuild -project MagicCamera.xcodeproj -scheme MagicCamera \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test 2>&1 | grep "failed ("
```

Kill the wedged services first (§0). Then diff the failing set against the
baseline four. **Ranked suspects** — all r71/r72 behaviour changes a test could
legitimately be pinning:

1. `DepthSampleConfidence.relativeJump` now counts a zero-depth neighbour as a
   full jump (was: skipped), to match the kernel.
2. `frameGrade` floored at `motionFloor` instead of 0.
3. `affordablePageBudget` no longer uses `keyframeCount`, and now reads live
   `os_proc_available_memory()` — so it is **not a pure function of its
   arguments**. Any test asserting a specific count will be flaky by design; the
   current tests pin invariants instead.
4. Defaulted `isCancelled:` parameters added to `MeshOptimizer.smooth`,
   `MeshDecimator.decimate`, `MeshBoolean.combine`, `ModelStudioBaker.bake`.

### 2.2 SECOND — CPU cost per atlas page (the remaining ship risk)

The 2026-07-30 run produced a `cpu_resource` report:

```
90 seconds cpu time over 139 seconds (65% cpu average),
exceeding limit of 50% cpu over 180 seconds
```

`action taken: none` — a warning, not a kill. Footprint peaked at 2178 MB, clear.
But iOS *can* kill for CPU, and a big room now legitimately spends ~94 s.

**Measured cost, from `bake timing`:** ~14–17 s **per page** on 90 k triangles;
scoring is 13–68 ms. So the cost is the 8192² sheet itself, not the geometry on
it: gutter fill over 67 M texels, seam levelling, JPEG encode. Both earlier cost
models (`tris × kf × pages`, then `tris × page`) had the wrong shape; the current
budget is a page count against live headroom.

Concrete levers, cheapest first:
- **`TextureAtlas.fillGutters` runs over all 67 M texels of every sheet.** It only
  needs the band around occupied charts. Restricting it to chart-adjacent texels
  should be most of the win and is behaviour-preserving.
- Same question for `TextureSeamLeveler.level` and `repairUnwrittenTexels` — are
  they full-sheet or chart-local?
- The JPEG encode of an 8192² sheet is not free either; check whether it can go
  through a hardware encoder.

Do **not** simply reduce the page count — that is the texture-quality win the last
three rounds bought.

### 2.3 THIRD — thin structures: fix clustering, not SOR

Precisely located by the funnel, first try:

```
isolate funnel — 22025 → mask 21945 → hull 21945 → cluster 431
prep funnel    — 21945 → confident 21922 → outliers 20589
```

**`PointCloudSegmenter.isolateMainSubject` loses 98%.** Statistical outlier
removal — which r72 named as prime suspect — drops 6%. r72's ranking was wrong;
tuning SOR would gain nothing and let bleed back in everywhere.

Why: a steel-rimmed glasses frame is not one dense blob. The rim fragments into
many small connected components and clustering keeps only the largest.

**Candidate fix, unverified:** keep every component that is *small and near* the
anchor or the largest component, instead of the single largest. The
small-and-near guard is what stops a room's furniture all merging.

The `gutted-fallback` safety net **does** work — that scan still produced 9575
triangles. So this is a quality improvement, not a rescue. The r72 41-triangle
case (Object+, voxel 2 mm, `kept 5531`) has **not recurred** and no funnel was
ever captured for it; do not chase it without one.

### 2.4 FOURTH — Tier 4.3, the 28 mm geometry floor (now evidence-backed)

Every room in the last export came back `bound by noise-floor · cell 28 mm`. That
is the datum 4.3 was waiting for: the floor, not the triangle budget, is what
limits room geometry now.

🔴 **The user has seen the torn-paper regression first-hand and asked for
caution.** Do NOT change the constant. Ship it as a **Settings switch** so it can
be A/B'd on device, the same way Sample confidence is. ICP cut registration noise
from ~16 mm to ~2 mm, so there is headroom in principle — but per-sample depth
noise is a separate floor and is what tears.

### 2.5 Then, in no particular order

- **Chart shatter at scale, unmeasured.** The big room returned
  `uv 25404 charts · gate 0.25` where smaller rooms get `gate 0.75`.
- **`OperationRunner` has had no independent review.** A `swift-reviewer` pass was
  started twice and died both times. It is build-green. The property most worth
  checking: `completion` must run **exactly once on every path**, because
  `perform` bridges it to a checked continuation and a skipped path hangs the
  caller forever.
- Tier 3.2 (decompose `SpatialScanViewModel`, 1734 + 1961 LOC), 3.3 (`ScanTuning`
  — constants scattered over 10+ files), 3.4 (8 files over 800 LOC, largest 2031).
- Tier 4.1 on-device AI (FoundationModels auto-name/describe).
- Tier 4.5 SceneKit → RealityKit (XL; not before 1.0 is locked).
- **User steps, unchanged:** App Store Connect record + first Archive (registers
  the iCloud container + App Group), screenshots (6.9"/6.5" iPhone + iPad),
  description, privacy label ("Data Not Collected"), final name + bundle id.

---

## 3. Rules that have burned this project — do not relearn them

1. **A comment asserting an invariant is not evidence it holds. Grep first.**
   Three separate bugs came from believing one: Studio's "the mesh passes check
   `Task.isCancelled`" (they contained zero such checks), r67's "candidate scoring
   runs per page" (it is hoisted above the loop), and "peak memory is a single
   atlas however many pages" (no `autoreleasepool`, so every page leaked).
2. **Validate atlas/geometry work against REAL device exports, never synthetics.**
   False results 4× so far. Exports are duplicated-corner soup — both sides of
   every triangle — so **halve before quoting triangle counts** and dedupe before
   any connectivity work.
3. **Geometry detail floor is ~cm** (measured again: 15.3 mm room / 3.7 mm object
   local-plane RMS). Detail lives in the **texture**. Don't chase sub-cm geometry.
4. **Add the breadcrumb before tuning.** Every diagnosis in r71–r73 came from one:
   `memory` found the autoreleasepool leak, `bake timing` killed two wrong cost
   models, `bound by` unblocked 4.3, the funnels overturned a suspicion ranking on
   their first run.
5. **`cancel()` vs `requestStop()` is a real distinction.** `cancel()` invalidates
   (the data changed underneath — discard, new scan). `requestStop()` keeps the
   result if it lands (resource pressure; the data is unchanged). Conflating them
   binned 94 s of completed, correct work.
6. **Integer division makes budget thresholds sharp** — `500_000 / 253_062 == 1`
   silently gave a big room one page.
7. **`SIMD3<Float>` is 16 bytes / 16-byte aligned.** Never load one straight from
   a 12-byte-strided ModelIO buffer; it segfaults. Read component floats.
8. Test suite is not green and that is partly expected — see §2.1.

---

## 4. What to ask the user to scan

Ranked by what it would verify:

1. **A big room, then export USDZ.** Confirms the r73 discard fix: after
   `memory pressure — critical`, the bake must now **land** — look for
   `■ Building textured surface — ok`, not `discarded`.
2. **The steel-rimmed glasses again**, if clustering gets fixed. The funnel line
   `isolate funnel — … → cluster N` is the whole measurement.
3. **A matte compact object** (mug, pot, shoe) as the control against the glasses.
4. **An object scan then Method → Photogrammetry.** Never yet run on device. Needs
   20+ keyframes, a full slow orbit, even light; takes minutes.
5. **Two rooms of very different size**, if 4.3 gets its switch — A/B the floor.
