# NEXT CHAT — start here

_Written 2026-07-27 at the end of round r70. Read this first, then
[HANDOFF.md](HANDOFF.md) §0a for the detail. This page exists for one job: the
user is about to paste a **device diagnostics export** from an r70 build, and
this tells you how to read it._

---

## 1. Where the code is (get this wrong and you waste the session)

| | |
|---|---|
| **Branch** | `claude/cloud-mesh-postprocess-optimize-8cb455` |
| **Worktree** | `/Users/keks/Developer/Magic-camera/.claude/worktrees/cloud-mesh-postprocess-optimize-8cb455` |
| **HEAD** | `dbbb54b` (= `origin/…`, pushed) |
| **`main`** | `2d5c7a4` — **176 commits STALE, not where the work lives.** Never build it. |

⚠️ **The shell's cwd flaps between the main repo and the worktree, mid-session.**
It bit this round: a commit meant for the branch landed on stale `main`. Use
`git -C "$W"` with an absolute `$W` for **every** git command, `-project <abs>`
for `xcodebuild`/`xcodegen`, and after any commit verify with
`git -C "$W" show --stat --format="" HEAD` — the *file list* is what catches a
commit that went to the wrong tree.

Build: `xcodegen generate` after adding/removing files (the generated
`project.pbxproj` **is** committed). Batch edits, build once at the end — the
user's machine is slow.

---

## 2. Reading the diagnostics export

Settings ▸ Diagnostics exports the breadcrumb log + MetricKit. Lines to find,
in priority order.

### 2.1 `sample grading` — the NEW line, and the whole point of this round

```
sample grading — mean 0.87 · doubtful 3.2% (<0.25) · min 0.04
```

Emitted from `SpatialScanViewModel.swift:1207`, only when
**Settings ▸ Sample confidence** is on.

| Reading | Meaning | Action |
|---|---|---|
| mean ≳0.80, doubtful low single-digit % | healthy | nothing — this is the target |
| doubtful ≳15–20%, or mean <0.7 | grading is biting **real geometry** | raise the floors in `DepthSampleConfidence.swift` (below), or have the user A/B with the Settings switch |
| doubtful ≈0%, mean ≈1.0 | grading isn't biting at all | lower `minGrade` / tighten the knees — but only if bleed is still visible |
| line absent | the switch is **off**, or the build predates r70 | confirm which before drawing any conclusion |

**The floors, all in `MagicCamera/SpatialScan/DepthSampleConfidence.swift`** (Swift
is the single source of truth; the Metal kernel receives them via the
`SampleGrading` uniform, so never hand-edit the shader):

| Constant | Value | Signal |
|---|---|---|
| `edgeKnee` / `edgeFloor` | 0.35 / 0.28 | silhouette proximity |
| `trustedCos` / `grazingCos` / `incidenceFloor` | 0.50 / 0.15 / 0.15 | **grazing incidence — the new one, most likely to over-reach** |
| `trustedRange` / `rangeFloor` | 1.5 m / 0.75 | distance |
| `trustedRadius` / `radialFloor` | 0.65 / 0.85 | radius in frame |
| `steady*` / `blurred*` / `motionFloor` | 0.35, 0.20 / 1.20, 0.60 / 0.50 | camera motion |
| `minGrade` | 0.10 | **the only thing that rejects** |
| `lowConfidenceMark` | 0.25 | the "doubtful" bar in the breadcrumb |

🔒 **INVARIANT — do not break it while tuning:** no single signal may reject a
sample. Each factor only ramps toward its own floor; a sample dies solely when
the *product* falls under `minGrade`. That is what makes the grading safe (it
takes several independent signals agreeing — bleed's signature — to drop
anything). `testNoSingleSignalCanRejectASample` pins it. If a fix requires one
signal to veto on its own, the fix is wrong.

**What the user is actually judging:** does the bleed they have been reporting
(fringes at furniture/curtain edges, flying pixels around object silhouettes)
get better? Ask for a with/without comparison using the Settings switch if the
numbers look fine but the scan doesn't.

**Watch for the over-reach failure mode:** holes in corridor walls and far room
walls. Those surfaces are legitimately seen edge-on, so grazing incidence is the
factor that would wrongly eat them. If that appears, raise `incidenceFloor`
first (0.15 → 0.25), not `minGrade`.

### 2.2 The rest of r65–r70, still un-verified on device

| Line | Healthy | Notes |
|---|---|---|
| `lattice — res N · cell X mm · floor 28 mm` | cell ~28 mm, **consistent between similar rooms** | r66. Swinging 45–55 mm = the mean-spacing bug is back. If a far wall holes, raise the percentile 0.35 → 0.5 |
| `bake budget — …` | appears only on huge rooms | r67 cost cap. Its presence is fine; the scan **completing** is the test |
| `pages N · ~X mm/texel` | 4 pages ≈ 0.97 mm/texel on a big room | r65. Then check USDZ **and** GLB show every page — a dropped page = black/untextured patches |
| `scan icp — applied/attempted · avg · cum` | applied/attempted near 1, avg ~2 mm | `cum` changed meaning in r60 — old readings are not comparable |
| `object model — mesh N tris` | ~2–3× the pre-r66 count | |
| `memory pressure` | absent is fine | if `.critical` fires, the app should toast and stop, not die |

### 2.3 Also worth a glance
- Live Activity / Dynamic Island (needs iPhone 14 Pro+ and Live Activities on).
- First-run onboarding + the camera permission prompt arriving **after** the
  explanation, not cold.
- Control Center: "Start Scan" / "Scan Gallery" controls (iOS 18+).

---

## 3. Rules that have burned this project — do not relearn them

1. **Validate atlas/geometry changes against REAL device exports, never
   synthetics.** This has produced false results 4×. Dedupe double-sided faces
   before any connectivity work (textured saves/USDZ are duplicated-corner soup).
2. **Geometry detail floor is ~cm** (LiDAR depth noise). Detail lives in the
   **texture**, not the lattice. Don't chase sub-cm geometry; don't re-fine the
   28 mm floor without device proof — torn-paper regressions are catastrophic.
3. **Bake cost ≈ tris × keyframes × pages.** Anything that raises any factor must
   respect `bakeCostCeiling` (16 M) or the iOS CPU watchdog kills the app.
4. **Add a breadcrumb before tuning blind.** r66's `lattice` line is the only
   reason the r67 crash was diagnosable.
5. **The test suite is NOT green and that is expected.** 283 tests, 4 failures —
   `OrbitCoverageTracker` ×2, `MarchingCubes`, `VisionGeometry`. All are
   x86_64-simulator float artefacts, **verified against parent `a598fb6`** by
   running the same classes in a throwaway worktree. Don't chase them as
   regressions; don't call the suite green either.

---

## 4. Roadmap position

**All Tier-0 code, all of Tier 1 (1.1–1.5) and all of Tier 2 (2.1–2.8) are
DONE.** There is **no remaining ship-blocking code work.**

What is left:
- **Device verification** (this document) — the critical path.
- **User steps:** App Store Connect record + first Archive (registers the iCloud
  container + App Group), screenshots (6.9"/6.5" iPhone + iPad), description,
  privacy label ("Data Not Collected"), final app name + bundle id.
- **Tier 3** (architecture): the natural next item is `ScanTuning` — the scan
  constants are scattered across `CaptureQuality`, `ScanConfig`,
  `DepthSampleConfidence` and the reconstruction path, which makes tuning rounds
  slower than they need to be. **Do it after the device round**, so the numbers
  being centralised are the ones that survived verification.
- **Tier 4**: on-device AI (auto-name/describe scans via FoundationModels — fits
  the "nothing leaves your device" story), SceneKit→RealityKit (XL — do not start
  until 1.0 is locked).

---

## 5. Open follow-ups from r70

- A `swift-reviewer` pass over `af6237a`+`dbbb54b` was started twice and died
  both times (session limit, then a stalled stream). **It never produced
  findings** — the code is build-green and test-neutral but has had no
  independent review. Worth re-running early, scoped to
  `DepthSampleConfidence.swift` + `ScanCompute.metal` (GPU/CPU divergence) and
  `ModelStudioViewModel.runHeavy` (is the background-task assertion always
  balanced? does `heavyWorkCancel` behave if two heavy ops ever overlap?).
- Studio's `concurrentPerform` per-triangle passes still run to completion —
  bounded and short, but the last remaining cancellation gap.
