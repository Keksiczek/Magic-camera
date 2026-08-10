> **HISTORICAL RECORD — do not plan from this file.** It is the state of
> one past round, kept for the reasoning behind constants and decisions.
> Current status lives in [README](README.md), [VISION](VISION.md) and
> [07-roadmap](07-roadmap.md), verified 2026-08-10.

# HANDOFF → r86

_Written 2026-08-03 at the end of r86. Self-contained. Supersedes
[HANDOFF-r77.md](HANDOFF-r77.md); read that one only for the pre-r78 history._

---

## 0. Where the code is

| | |
|---|---|
| **Branch** | `claude/cloud-mesh-postprocess-optimize-8cb455` |
| **Worktree** | `/Users/keks/Developer/Magic-camera/.claude/worktrees/cloud-mesh-postprocess-optimize-8cb455` |
| **HEAD** | `3ac5796` |
| **`main`** | 190+ commits stale. **Never build it.** |
| **Pushed?** | **No.** Everything since `9374616` is local. |
| **Suite** | 353 cases, 3 failures — the permanent floor, see §4 |

⚠️ The shell's cwd flaps between the main repo and the worktree. Use `git -C "$W"`
with an absolute `$W`, `-project <abs>` for xcodebuild, and check a commit landed
with `git -C "$W" show --stat --format="" HEAD` — the *file list* catches a commit
that went to the wrong tree.

`xcodegen generate` **from inside the worktree** after adding or removing files.
Only one simulator is installed: **iPhone 17**. A full build+test is ~8 minutes.

When `xcodebuild` dies after three lines, or `simctl list devices` returns
nothing, the Xcode services are wedged, not your code:

```bash
killall -9 XCBBuildService com.apple.CoreSimulator.CoreSimulatorService xcodebuild; pkill -9 -f SourceKitService
```

---

## 1. The 2026-08-03 device round — what it settled

The user scanned with r77 and sent diagnostics. Confirmed working, do not
re-investigate:

- **Thin-subject clustering is fixed.** `isolate funnel — 299747 → mask 280846 →
  hull 125306 → cluster 7872`, and `→ cluster 822` on another. It was **431**.
- **The sphere-snap gates hold.** `shape snap — revolutions 1 · spheres 0` and
  `revolutions 2 · spheres 0` — boxes are no longer rounded, and real revolutions
  still fire.
- **The finer-lattice A/B works and binds**: `lattice — res 117 · cell 20 mm ·
  bound by noise-floor · floor 20 mm (fine)`.
- Capture itself: *"scan works nicely, Quick and Max both make nice results,
  object crop is good."*

### 1a. The bake cost model was wrong a THIRD time

r77 said the cost was "the 8192² sheet itself — gutter fill, seam levelling, JPEG
encode". Measured:

| tris × kf | pages total | gpu | fallback | repair | seam | gutters | jpeg |
|---|---|---|---|---|---|---|---|
| 10557 × 15 | 16672 | 4370 | **7619** | 485 | 1538 | 2073 | 558 |
| 69507 × 25 | 19192 | **8630** | 6293 | 3350 | 85 | 292 | 524 |
| 138719 × 48 | 21996 | **14886** | 3932 | 2045 | 161 | 299 | 660 |
| 55978 × 24 | 10140 | **6460** | 2 | 389 | 2897 | 264 | 122 |

Gutters are 264–2073 ms and JPEG 122–660 ms — noise. The cost is **`gpu`** (the
multi-view kernel, scaling with tris × keyframes) and then **`fallback`**, which
has one cause:

| unseen | fallback |
|---|---|
| 3050/10557 (29 %) | **7619 ms** |
| 23/55978 (0.04 %) | **2 ms** |

`fallback` is `paintFallbackTriangles` repainting triangles no keyframe ever saw.
**The CPU lever is keyframe coverage, not the atlas.** Do not optimise the gutter
flood further; it is already the cheap part.

### 1b. Chart shatter, measured at last

| charts | pad share | median chart |
|---|---|---|
| 1121 | 4 % | 99 px |
| 4167 | 15 % | 14 px |
| 6808 | 20 % | 13 px |
| 16294 | **27 %** | **9 px** |

A 9 px chart with 4 px of padding on every side is 72 % border. **The lever is
`ChartAtlas.chartPadPx`, not the growth gate** — the gate search never even ran on
these (density was already at target, so only the tightest candidate is tried).

### 1c. Still open from the round

- **Memory is on the edge**: repeated `memory pressure — critical`, down to
  `headroom 246 MB` at 2.7–3.1 GB used.
- A GPU `.ips` arrived: "firmware-detected lockup", 2026-08-02 11:00, no stack.
  One event, nothing to act on yet. If it recurs, it becomes real.

---

## 2. What r78–r86 changed

Eleven commits, **none device-verified except where §1 says otherwise**.

| commit | what |
|---|---|
| `96f0cf3` | Tier 3.4: split the three biggest files (pure moves) |
| `c79ac1b` | `docs/analysis/SCAN-TUNING.md` — the map of ~70 tuning constants |
| `32754a0`, `3aaf59c` | `docs/analysis/UX-AUDIT.md` — the audit and its plan |
| `b48950c` | **Capture picker split into Subject × Detail** |
| `64c2762` | Component-trim guard — stop choosing between two subjects |
| `f40aaab` | ROI sphere placement + RealityKit preview withdrawn |
| `262589d` | **Post-process offered, not taken** — recipes and the panel |
| `3ac5796` | **Detail = density; budget = a device ceiling**; scan options panel |

### The capture picker (`CaptureProfile`)

Was one five-way enum — Draft/Balanced/Max/Object/Room — whose own comment
admitted "Object and Room have no four-tier equivalent, so they borrow existing
slots". Now two questions: **Subject** (Object / Room / Area) × **Detail** (Quick /
Balanced / Max). Area is the honest name for the profile the old density tiers ran
and which had never had one.

**The five old combinations are byte-identical**, asserted field by field against
the old enum. The four new pairs are compositions of tested pieces but have never
run on device — `isLegacyCombination` says which is which. The device round used
Quick and Max and liked both.

### Post-process (`ScanRecipe`, `PostProcessPanel`)

A scan now **always lands on its points**. Room used to auto-build a textured
surface the moment capture ended, taking the only interesting decision before the
user had seen anything.

The user's rule, verbatim: *"I want to be able to click together the same
post-process it would have done by itself."* Enforced structurally, not by
discipline: `ScanRecipe.standard` is built from `ScanIntelligence.heuristicPlan` —
the same function the app has always planned with — and `runRecipe` is the only
executor, so a button runs exactly what the disclosure is showing. `.model` adds
isolate + closeBase; `.surface` removes exactly those two.

### Density and the budget (`CaptureBudget`)

The point budget used to move with the detail tier, which made it the thing
deciding how much of a room a scan could cover. Detail now moves the voxel and
nothing else; the budget is one setting — Careful 1.5 M / Standard 3 M (default,
= what shipped) / High 4 M.

### Scan options (`CaptureOptionsPanel`)

On the scan screen, folded away, every row with a line saying what it is for.
**Only things that do something appear** — the octree / variable-resolution
reconstruction is deliberately absent because it is not wired (§4).

---

## 3. What to do next

### 3.1 Device round on r78–r86

Nothing below is worth doing before this. Ask for:

1. **A room, Room × Balanced, then Surface from the panel, then export USDZ.**
   Checks the new landing-on-points flow, the recipe, and the winding fix.
2. **The same room with the disclosure edited** — turn a step off and confirm the
   run honours it (`recipe` breadcrumb prints "(edited)").
3. **An object, Object × Max, then 3D model.** Confirms isolate + closeBase.
4. **Scan options ▸ Point budget = High** on a big room — this is the 4 M path and
   the memory headroom was already 246 MB.
5. A tap-to-target on an object, to see the sphere now sitting **around** the
   subject rather than pinned to its front face.

Read: `recipe`, `bake timing`, `uv gate search`, `isolate funnel`, `shape snap`,
`lattice`, `memory pressure`, `component trim`.

### 3.2 Then, in order

1. **`chartPadPx`** — §1b says this is the lever, with numbers. A 9 px median
   chart cannot afford a 4 px border. Consider scaling the pad with chart size,
   with a floor of 1–2 px for mip safety.
2. **Keyframe coverage** — §1a says `unseen` drives the second-biggest CPU cost.
   Either capture more/better-placed keyframes, or make `paintFallbackTriangles`
   cheaper. 29 % unseen on one scan is the number to attack.
3. **Fix or drop the RealityKit preview.** Withdrawn from Settings, code intact.
   The prime suspect is written into `AppSettings.realityKitPreview`: RealityKit
   ignores `faceCulling = .none`, which is why the USDZ exporter emits explicit
   back-faces. Try that first.
4. **Multi-object** — the decision is still the user's. See UX-AUDIT §3 item 5:
   (a) keep one mesh but stop destroying parts of it, or (b) real N-object support
   through to `StageStore`. (a) satisfies the complaint and is far cheaper.
5. **The bottom bar's hierarchy** — UX-AUDIT 2a-5..7. It now carries one more
   panel, so re-look once the user has held it.
6. **Finish the production-readiness audit** — UX-AUDIT §2c lists exactly what is
   unchecked: permission-denied paths, silent service-layer failures, data safety
   in the stores, disk-full, no-LiDAR degradation.

---

## 4. The permanent test floor

**353 cases, 3 failures, and all three are in code the shipping pipeline never
runs.** Anything else is new.

- `AdaptiveOctreeTests.testCurvedSubdividesFinerThanFlat` — a float tie.
- `AdaptiveSurfaceReconstructorTests.testReconstructsAPlaneNearItsSurface`.
- `MeshLouverSnapTests.testSlatStackEvensSpacing` — louver snap has been disabled
  in the pipeline since r56.

`AdaptiveOctree` and `AdaptiveSurfaceReconstructor` are built but were never
wired; louver snap false-fired on the marching-cubes lattice, reading a plain room
as a 120-slat blind and moving 95 % of its vertices. **Fix them or delete them** —
this is still the user's call, and carrying three permanent failures means every
round starts by re-deciding whether the suite is green.

Counting rules that cost two rounds: count *cases* with `grep "' failed ("`, not
XCTest's assertion tally; capture xcodebuild with `grep ": error:"`, not
`^Test Case`, which its timestamped lines defeat.

---

## 5. Rules that have burned this project

1. **A comment asserting an invariant is not evidence. Grep first.** Five so far,
   the latest being marching cubes' "reversed winding so faces point outward",
   which pointed them inward.
2. **Cost models about this bake have now been wrong three times.** Measure with
   the `bake timing` split before optimising anything in it.
3. **Validate atlas/geometry work against REAL device exports, never synthetics.**
   Exports are duplicated-corner soup — halve before quoting triangle counts.
4. **Geometry detail floor is ~cm.** Detail lives in the texture.
5. **Add the breadcrumb before tuning.** Every diagnosis in r71–r86 came from one.
6. **`cancel()` vs `requestStop()`** — `cancel()` invalidates (the data changed);
   `requestStop()` keeps a result that lands (resource pressure). Conflating them
   binned 94 s of finished work. Pinned by `OperationRunnerTests`.
7. **`SIMD3<Float>` is 16 bytes / 16-byte aligned.** Never load one from a
   12-byte-strided buffer.
8. **A single chart cannot straddle two atlas pages.** The packer spills whole
   charts, so a continuous surface pages exactly once however large.
9. **Alert buttons dismiss the alert.** Anything that must stay open is a sheet.
10. **A type's `private` members are file-scoped.** Splitting a type across files
    is a visibility decision, not a move — see HANDOFF-r77 §5.

---

## 6. The documents

- [UX-AUDIT.md](UX-AUDIT.md) — the UI findings and the redesign plan, with what is
  done and what is still the user's decision.
- [SCAN-TUNING.md](SCAN-TUNING.md) — every tuning constant, what it decides, and
  the traps around it. **Update it when you change a value.**
- [HANDOFF-r77.md](HANDOFF-r77.md) — the previous round; still the reference for
  the test-suite history and the file-split reasoning.
