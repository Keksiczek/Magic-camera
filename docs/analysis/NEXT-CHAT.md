# NEXT CHAT — start here

_Written 2026-07-28 at the end of round **r71**, the first device round on r70.
Read this, then [r71-device-round.md](r71-device-round.md) for the measurements
and [HANDOFF.md](HANDOFF.md) for the long-form state. The user is about to paste
another device diagnostics export; this tells you how to read it._

---

## 1. Where the code is (get this wrong and you waste the session)

| | |
|---|---|
| **Branch** | `claude/cloud-mesh-postprocess-optimize-8cb455` |
| **Worktree** | `/Users/keks/Developer/Magic-camera/.claude/worktrees/cloud-mesh-postprocess-optimize-8cb455` |
| **`main`** | 176+ commits STALE, not where the work lives. **Never build it.** |

⚠️ **The shell's cwd flaps between the main repo and the worktree, mid-session.**
Use `git -C "$W"` with an absolute `$W` for **every** git command, `-project <abs>`
for `xcodebuild`/`xcodegen`, and after any commit verify with
`git -C "$W" show --stat --format="" HEAD` — the *file list* is what catches a
commit that went to the wrong tree.

`xcodegen generate` after adding/removing files. Batch edits, build once at the
end — the user's machine is slow.

---

## 2. What r71 changed, and what the next export has to confirm

r71 fixed a **ship blocker** that r70's export exposed: the app was
jetsam-killed mid-bake, and the retry path caused it. It also found that the
`bake budget` cost cap was built on a false premise and had been silently
costing the room texture 2×.

**Nothing below is device-verified.** That is the whole job of the next export.

### 2.1 The kill (highest priority)

Reproduce it: scan a large room (~6-7 m, several minutes), then tap **Build
textured surface**.

| what to check | healthy |
|---|---|
| a second tap while a bake is unwinding | refused, toast "Still finishing the last job" |
| after a `.critical` cancel | toast points at reopening the scan, not a bare retry |
| the app | **survives** — no `app launch` line right after `memory pressure` |

### 2.2 The new `memory` breadcrumb — read this before theorising

```
memory — after capture · used 1420 MB · headroom 780 MB
memory — Building textured surface start · used … · headroom …
memory — Building textured surface end · used … · headroom …
memory pressure — critical · used … · headroom …
```

This did not exist. It answers the question r70's export could not: **is capture
or the bake holding the memory?** The tell from r70 was that the same bake
completed in 55 s in a fresh process, which points at capture-side residue — but
that was inference. Now it is measurable.

If `after capture` is already most of the budget → the fix is a pre-bake shed of
recorder scratch (fusion cells, voxel grid, ICP cells). If the bake's own delta
dominates → the fix is the atlas/slice allocation. **Do not implement either
until this line says which.**

### 2.3 The atlas pages (biggest quality win)

r70 shipped the room at a **measured 2.63 mm/texel** because `bake budget`
collapsed 4 pages to 1. The cost model charged paging for the `tris × keyframes`
scoring, which is hoisted above the page loop and does not repeat per page —
false at r67's own commit, verified.

| line | healthy |
|---|---|
| `bake budget — … → pages ≤ 2` | the corrected model biting |
| `pages 2 · ~1.86 mm/texel` | 1.41× sharper than r70 |
| `bake timing — scoring N ms · pages N/N ms` | **the number the ceiling is guessing at** |

`bakePagingCeiling = 560_000` (`triangle · page`) is calibrated on three device
timings, but the *split* between fixed and per-page cost has never been measured.
`bake timing` measures it. **Replace the estimate with that number** — if a page
turns out cheap, raise the ceiling toward 4 pages; if expensive, lower it.

Watch bake wall-clock: r70's single-page bake was 39 s. Two pages must stay well
under the ~90 s that killed r67.

### 2.4 Photogrammetry in the app's own mode (NEW feature — verify it runs at all)

`ReconstructionMethod.photogrammetry` is a fifth method in the app's own review,
backed by `KeyframePhotogrammetry.swift`: it feeds the scan's own keyframes to
`PhotogrammetrySession` instead of meshing the point cloud. This is the one path
not bound by the LiDAR depth-noise floor (3.7 mm object / 15.3 mm room).

**Verify, on an OBJECT scan first** (Apple's session is object-centric; rooms are
the inverse topology and are offered with a "Best for objects" hint, not a
promise):

| check | expected |
|---|---|
| the picker | shows "Photogrammetry" on device, absent in the simulator |
| `photogrammetry — N of M keyframes` | N ≤ 160, M = the scan's keyframes |
| progress toasts | stage names advance; it takes MINUTES, not seconds |
| `photogrammetry — mesh N tris · textured` | compare N and detail against the LiDAR path on the same subject |
| failure | actionable text ("Only N photos…"), not a generic toast |

### 2.5 `support check` — the object path's crop

New line. The 2026-07-28 object cloud was **74% tabletop** while the capture
claimed the support had been cropped, and the `crop-trusted` branch skipped
isolation on that claim. Now verified before the shortcut is taken.

```
support check — densest 6 cm slab holds 74% of 62143 pts (4.6× denser than the rest) → support SURVIVED the crop — isolating
```

Healthy on a genuinely clean object scan is `→ crop trusted`. If a good object
scan starts saying "SURVIVED", the gate is over-reaching — raise
`supportSlabDensityRatio` (2.5), **not** `supportSlabFraction`.

### 2.6 The rest

| line | healthy | if not |
|---|---|---|
| `lattice — … · bound by X` | — | **new.** Names which of four limits sized the mesh. r70 gave 42 mm under a `floor 28 mm` label. Fix the term it names; don't move the 28 mm floor blind |
| `scan icp — … · frozen N% of sweep` | absent, or single digits | **new.** r70 froze at 115 s of a 400 s walk = 70% uncorrected. If it repeats, make the 0.30 m bound a rate (~`0.30 + 0.06/min`, cap 0.60, objects unchanged) |
| USDZ file size | ~30 MB, not 94.5 MB | the atlas should now be `atlas_0.jpg` inside, not `texgen_0.png`. **Also confirm AR Quick Look still textures it** |
| `sample grading — mean … · doubtful …` | mean ≳0.80, doubtful single-digit % | r70 measured 0.66/6.2% (room) and 0.85–0.90/1.8–2.9% (objects) — **healthy, not implicated in anything** |
| `unseen N/M` | r70 was 18.9% | still ~1/5 of the room cloud-painted rather than photographed |

---

## 3. Rules that have burned this project — do not relearn them

1. **Validate atlas/geometry changes against REAL device exports, never
   synthetics.** This has produced false results 4×. Dedupe double-sided faces
   first — exports are duplicated-corner soup, and both r71 exports were exactly
   2× (506 124 = 2 × 253 062). Halve before quoting triangle counts.
2. **Geometry detail floor is ~cm** (LiDAR depth noise — measured again this
   round: 15.3 mm room, 3.7 mm object plane RMS). Detail lives in the **texture**.
   Don't chase sub-cm geometry; don't move the 28 mm floor without device proof.
3. **Bake cost is `tris × keyframes` ONCE plus `tris × pages` per page.** The old
   `tris × keyframes × pages` model was wrong and cost the texture 2×. Don't
   restore it.
4. **Add a breadcrumb before tuning blind.** Four of r71's changes are breadcrumbs,
   not fixes, for exactly this reason.
5. **A comment claiming an invariant is not evidence it holds.** Two of r71's
   findings were doc comments that were plainly false in the same file — Studio's
   "the mesh passes check `Task.isCancelled`" (they contained zero such checks)
   and r67's "candidate scoring runs per page" (it is hoisted). Grep before you
   trust.
6. **The test suite is NOT green — and at r71 it got WORSE, unexplained.**
   Baseline was 283 tests / 4 failures (`OrbitCoverageTracker` ×2,
   `MarchingCubes`, `VisionGeometry` — x86_64 simulator float artefacts, verified
   against parent `a598fb6`). **A full r71 run reported 288 tests / 22 failures.**
   ⚠️ **See §6 below — this is the first thing to resolve.**
7. **`SIMD3<Float>` is 16 bytes / 16-byte aligned.** Never load one straight from
   a 12-byte-strided ModelIO buffer — it segfaults. Read component floats.

---

## 4. Roadmap position

All Tier-0 code and all of Tier 1 & 2 remain done. r71 added no features; it
fixed a crash, a texture-quality regression and six review findings.

Left:
- **Device verification of r71** — the critical path (§2).
- **User steps:** App Store Connect record + first Archive (registers the iCloud
  container + App Group), screenshots (6.9"/6.5" iPhone + iPad), description,
  privacy label ("Data Not Collected"), final app name + bundle id.
- **Tier 3** (architecture): `ScanTuning` — the scan constants are scattered
  across `CaptureQuality`, `ScanConfig`, `DepthSampleConfidence`,
  `PhotoTextureBaker` and the reconstruction path. Do it *after* the device round.
- **Tier 4:** on-device AI (auto-name/describe via FoundationModels),
  SceneKit→RealityKit (XL — not before 1.0 is locked).

---

## 5a. r73 — what the 2026-07-30 export confirmed, and the one new bug

**Confirmed working on device:**

| | |
|---|---|
| r72 autoreleasepool fix | bake ends at 1353 / 1749 MB, **no kill** — was pinning at 2700 |
| multi-page atlas | big room **2.63 → 1.35 mm/texel**; smaller rooms 0.63 / 0.79 |
| USDZ as JPEG | `atlas_0.jpg` + `atlas_1.jpg` inside, **23.6 MB vs 94.5 MB**, AR Quick Look textures it |
| `bound by` breadcrumb | every room `bound by noise-floor · cell 28 mm` at res 195 / 131 / 113 — **consistent** |
| funnel breadcrumbs | named the thin-structure stage on the first try (§5c) |
| `support check` | correctly trusted a clean lamp scan that the absolute bar alone would have failed (§5c) |

**The one new bug — a completed bake was thrown away.** Fixed at r73:

```
09:30:56  memory pressure — critical · used 2735 MB · headroom 640 MB
09:31:34  texture-bake — 379440 tris · pages 2 · 1.35 mm/texel     ← FINISHED, correct
09:31:34  ■ Building textured surface — discarded · 94354 ms       ← binned
```

`.critical` called `cancelHeavyWork()`, which bumps the generation and therefore
guarantees the completing result is dropped as stale. But memory pressure does
not change the cloud — a bake that reaches the end is still valid, and by the
time it lands the pressure is over. Ninety-four seconds of finished work
discarded, which reads to the user exactly like a crash.

Fixed with `OperationRunner.requestStop()`: ask the job to stop **without**
invalidating it. Both memory-pressure handlers use it. The operation slot stays
claimed on purpose — the work really is still running, so the spinner is truthful,
and releasing it early is what previously let a retry start alongside the dying job.

**Still open — CPU, not memory.** The same run produced a `cpu_resource` report:
`90 seconds cpu time over 139 seconds (65% cpu average), exceeding limit of 50%
cpu over 180 seconds`, action taken *none* (a warning). Footprint peaked at
2178 MB, well clear. With the discard fixed those 94 s now yield a model, so it is
expensive-but-productive rather than pure waste — but a big room sits close to the
CPU ceiling. `bake timing` says ~14–17 s **per page** on 90 k tris, so the lever is
per-page cost (gutter fill over 67 M texels, seam levelling, encode), not scoring.

Watch also: the big room came back `uv 25404 charts · gate 0.25` where smaller
rooms get `gate 0.75` — chart shatter at scale is unmeasured.

## 5b. r72 — the memory kill, SOLVED from the r71 breadcrumb

The `memory` line added at r71 paid for itself on its first export
(`…20260729-105331`). The bake's page loop had **no `autoreleasepool`**.

`GPUTextureBaker.bakeMultiView` allocates Metal objects — a ~445 MB photo texture
array, a 268 MB output buffer, a 134 MB weight buffer. Metal objects are
Objective-C, so they land in the enclosing autorelease pool, and the whole bake
runs inside one synchronous `Task.detached` body whose pool is not drained until
the task **ends**. Every page's buffers therefore stayed live to the end.

The log measures it exactly:

| pages | `Building textured surface end` | outcome |
|---|---|---|
| 1 (17 644 tris) | used **1320 MB** | ✅ |
| 2 (34 380 tris) | used **2185 MB** (+865) | ✅ |
| 4 (93–114 k tris) | pins at **2700 MB**, headroom 675 MB | ❌ killed |

`used + headroom` was 3375 MB in every single reading — that is the jetsam limit.

**Why the user felt it as a regression** ("before it ran and completed"): r71's
`bakePagingCeiling` gave big rooms more pages. The 114 k-tri room got 4 where the
old model gave it 1 — and each extra page leaked ~865 MB.

Fixed at r72:
- `autoreleasepool` per page in **both** bake paths (multi-view and the
  single-best-view fallback), which makes the "peak memory is a single atlas"
  comment true instead of aspirational.
- `affordablePageBudget` is now a page **count against live
  `os_proc_available_memory()`**, not a function of geometry. Self-correcting: a
  bake started with a big cloud still resident gets fewer pages than the same bake
  in a fresh process — which is precisely the difference between the runs that
  died and the ones that completed.
- `bake budget` now reports headroom.

**The cost model was wrong in shape, twice.** `bake timing` settled it: 17 644
tris over 1 page took 5589 ms; 34 380 tris over 2 took 3598/4711 ms. **A page
costs ~4-5 s and ~865 MB almost independently of the triangles on it** — the work
is the 8192² sheet itself (gutter fill over 67 M texels, seam levelling, JPEG
encode), while scoring costs 2-7 ms. Neither r67's `tris × kf × pages` nor r71's
`tris × page` described that.

**Verify next:** a big room reaches `pages 2-4` and **completes**; `bake budget`
shows a sane headroom; `Building textured surface end` stays under ~2400 MB.

## 5c. Thin structures: an Object+ scan produced a 41-triangle model

```
04:42:54  lattice — res 42 · cell 3 mm · bound by spacing
04:42:55  object model — raw 111158 → kept 5531 → mesh 41 tris · isolate gutted-fallback
```

**111 158 points in, 41 triangles out**, off a clean capture
(`sample grading mean 0.85 · doubtful 0.9%`, `icp applied 84/85 · avg 0.6mm`).

**The subject was sunglasses with steel rims** (per the user). That reframes it:
not a mystery regression but the project's standing **thin-structure erosion**
weakness, in its most extreme instance yet — and the second-worst possible
subject for LiDAR besides (dark glossy lenses return almost nothing).

### ✅ ANSWERED at r73 — and the suspicion order was wrong

The 2026-07-30 export re-scanned the same glasses with the funnels in place:

```
isolate funnel — 22025 → mask 21945 → hull 21945 → cluster 431
prep funnel    — 21945 → confident 21922 → outliers 20589
object model   — raw 22025 → kept 21945 → mesh 9575 tris · isolate gutted-fallback
```

**Clustering is the guttor: `isolateMainSubject` cut 21 945 → 431, a 98% loss.**
Statistical outlier removal — which r72 ranked as *prime* suspect — drops only
6%. The ARKit mask and the keyframe visual hull cost essentially nothing.

So the fix belongs in `PointCloudSegmenter.isolateMainSubject`, not in SOR. A
wire frame is not one dense blob: the rim fragments into many small
components, and connected-component clustering keeps only the largest. Softening
SOR would have achieved nothing and let bleed back in everywhere.

Note the safety net **worked** — `gutted` was detected, `gutted-fallback` reverted
to the masked cloud, and the model came out at 9575 triangles rather than 41. The
r72 41-triangle case must have had a different shape (Object+, voxel 2 mm, `kept
5531`); it has not recurred, and no funnel was captured for it.

Candidate fix, unverified: let clustering keep every component within some
distance of the anchor / of the largest one, instead of the single largest —
a wire object is legitimately many components. Guard it on the components being
*small and near*, so a room's furniture doesn't all get merged.

Related standing item: memory notes "thin stems erode (carve + minNeighbors) →
subject splits" — same root, same stage.

### `support check` earned both of its conditions

Same export, the matte-plastic lamp:

```
support check — densest 6 cm slab holds 41% of 52314 pts (1.8× denser than the rest) → crop trusted
```

**41% is over the 40% absolute bar** — the single-condition version r72 first
wrote would have wrongly diverted this clean scan into the geometric isolation,
the exact regression that decimated the mouse/plate. The density ratio (1.8×,
under the 2.5× bar) is what kept it on the fast path. That is the sphere case the
unit test predicted, appearing in the field on the first try.

## 6. ⚠️ UNRESOLVED: the suite went 4 → 22 failures at r71

**Do this before anything else.** A full-suite run at `9b654a8` reported
**288 tests / 22 failures**, against a verified baseline of 283 / 4. The extra 5
tests are r71's own (3 support-check, 1 frame-grade, plus a rename), and those
were individually confirmed passing — `SegmenterAndBakerTests` 14/14,
`DepthSampleConfidenceTests` 25/25, `GPUTextureBakerTests` 5/5,
`ModelStudioHistoryTests` 6/6.

**The 18 extra failures were never identified.** The run's output was captured
through too narrow a grep (`^Test Case` misses xcodebuild's timestamped lines),
and every attempt to re-run died because CoreSimulator wedged — `xcrun simctl
list devices` returned nothing at all, even after killing
`com.apple.CoreSimulator.CoreSimulatorService`. The session ended there by
agreement, deliberately deferred rather than resolved.

What the partial output does say:

```
Executed 14 tests, with 2 failures     ← an unidentified class
Executed  5 tests, with 1 failure      ← VisionGeometryTests.testUpIsIdentity (known baseline)
Executed 14 tests, with 0 failures     ← SegmenterAndBakerTests (r71's, clean)
Executed 288 tests, 1 skipped, 22 failures
```

To resolve:

```bash
xcodebuild -project MagicCamera.xcodeproj -scheme MagicCamera \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test 2>&1 | grep "failed ("
```

Reboot the Mac first if `simctl` is still mute. Then diff the failing set against
the baseline four. **Prime suspects, in order** — all r71 behaviour changes that
a test could legitimately be pinning:

1. `DepthSampleConfidence.relativeJump` now counts a zero-depth neighbour as a
   full jump (was: skipped). Anything asserting on grading or unprojection
   output could move.
2. `frameGrade` floored at `motionFloor` instead of 0.
3. `affordablePageBudget` no longer uses `keyframeCount`.
4. `MeshOptimizer.smooth` / `MeshDecimator.decimate` / `MeshBoolean.combine`
   gained a defaulted `isCancelled` parameter — a default-valued closure argument
   should be source-compatible, but check for ambiguity at call sites.

## 5. Open follow-ups from r71

- **The object path drops 74% of its points** (`raw 62143 → kept 16406 → mesh
  9419 tris`) and the mesh bbox (13×16×22 cm) is much smaller than the cloud
  extent (30×18×48 cm). May be correct — `crop-trusted` is meant to trust the
  capture crop — but confirm with the user that the object that came out is the
  object they scanned.
- **`relativeJump` and depth holes.** The CPU path now matches the kernel, which
  treats a zero-depth neighbour as a full-size jump — so a texel bordering any
  depth hole is dropped as a silhouette. Defensible, but it erodes the rim around
  every dark/glossy patch. Worth its own A/B; it changes what capture keeps.
- **Studio's per-triangle `concurrentPerform` passes** still run to completion —
  bounded and short. The scan-side bake got slab-wise cancellation this round;
  Studio's equivalent did not.
- The design-resources repo the user linked is a **web** link list (CSS
  frameworks, JS chart libs). The only slice that maps to this app is **Product &
  Image Mockups**, for the App Store screenshots still on the critical path.
