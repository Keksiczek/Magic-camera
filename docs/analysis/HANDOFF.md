# HANDOFF — Magic Camera, next chat starts here

_Written 2026-07-25, updated 2026-07-27. Self-contained context + the plan to get
to a submittable 1.0. Read this first, then the numbered `docs/analysis/*` for
depth. Supersedes the status tables in
[06-appstore-readiness](06-appstore-readiness.md) and
[07-roadmap](07-roadmap.md) where they disagree — several items have since
shipped._

---

## 0a. Round r70 (2026-07-27) — what just landed

All build-green on the device target, **none of it device-verified.**

### Graded per-sample confidence — the anti-bleed change (NEW)
The user's own ask: "a point's confidence is computed from a few things +
coordinates — can we widen it so bleed can't happen?" It could, and this is the
answer. Until now every quality signal was a **hard gate**: over `edgeThreshold`
→ drop the texel, too fast a pose delta → drop the frame, below ARKit's
confidence level → drop the sample. Gates have to be loose enough not to hole
real geometry, and everything under the bar then entered at **full** confidence —
which is exactly how a flying pixel ends up with the same standing as a wall seen
twenty times.

`MagicCamera/SpatialScan/DepthSampleConfidence.swift` grades instead. Five
independent signals, each a multiplicative factor in 0…1:

| Signal | New? | Floor | What it catches |
|---|---|---|---|
| Silhouette proximity (graded `edgeThreshold`) | graded, was binary | 0.28 | texels that squeak just under the depth-jump bar |
| **Grazing incidence** (`\|n̂·r̂\|`, normal estimated from the depth map) | **new** | 0.15 | the big one — a flying pixel bridging a depth cliff has a normal ⟂ to the ray. Works even where no edge threshold is configured |
| Range | new | 0.75 | LiDAR noise grows with distance |
| Radius in frame | new | 0.85 | the dot pattern stretches toward the corners |
| Camera motion (pose delta) | graded, was binary | 0.50 | motion-blurred depth, now for every preset not just Object |

`confidence = arkitLevel × product(factors)`. Downstream this number is already
load-bearing — `ScanRecorder.fuse` uses it as the TSDF weight, and
`ReconstructionPipeline.dropLowConfidence(0.25)` drops what never earned belief —
so a doubtful sample barely moves the running mean and dies unless a later view
vouches for it.

**The rule that keeps this safe: no single signal may reject a sample.** Each one
only ramps toward its own floor; a sample is dropped solely when the *product*
falls under `minGrade` (0.10), i.e. when several independent signals agree. That
is bleed's signature (a depth cliff, seen edge-on, far away, while sweeping) and
not an honest-but-awkward measurement — a real wall at a grazing angle keeps 0.15
and recovers the instant it is seen from anywhere better. `testNoSingleSignalCanRejectASample`
pins that invariant.

- Constants live **only** in Swift; the Metal kernel receives them through the
  new `SampleGrading` uniform, so GPU / CPU-fallback / unit tests cannot drift.
- Kill switch: **Settings ▸ Sample confidence** (on by default). Off ⇒ byte-identical
  to the old behaviour.
- Telemetry: new `sample grading — mean X · doubtful Y% (<0.25) · min Z` breadcrumb.
- Tests: `Tests/MagicCameraTests/DepthSampleConfidenceTests.swift`.

**DEVICE VERIFY (this is the one to watch):** scan a room and an object.
① `sample grading` mean should be ≳0.8 with `doubtful` in the low single-digit %.
A big `doubtful` share means grading is biting real geometry → raise the floors or
A/B with the Settings switch. ~0% means it isn't biting at all. ② Compare the
bleed the user has been reporting (fringes at furniture / curtain edges, flying
pixels around object silhouettes) with and without the switch. ③ Watch for holes
in corridor walls and far room walls — the grazing-incidence signal is the one
that could over-reach there.

### Roadmap items closed in the same round
- **2.5 home taxonomy** — the biggest coherence gap in
  [08-coherence-and-ideas](08-coherence-and-ideas.md) is fixed. The home screen is
  grouped by **intent** (Scan a space / Capture an object / Your library / Create
  & edit) with a "best for" line under every entry, Live Depth demoted to a plain
  row, and the duplicated "Magic Camera" title replaced by a tagline. "Capture an
  object → Quick 3D" and "Scan a space → Spatial Scan" are the same engine, so the
  card now carries the profile: `AppRouter.startSpatialScan(profile:)` →
  `pendingCaptureProfile` → adopted in `SpatialScanView.onAppear` (mirrors the
  existing gallery-pick bridge). Without that the two entries would have been a lie.
- **2.3 per-scan widget deep link** — `magiccamera://scan/<id>` both halves in
  `WidgetSharing` (`scanURL`/`scanID`, percent-encoding included, since ids are
  file names). Small widget opens *its* scan; medium widget gives each tile its
  own `Link`. App side: `ScanLibrary.item(withFileName:)` + `ScanLibrary.load(_:)`
  (now shared with the gallery, so both paths stay in step), decoded off-main,
  falling back to the gallery when the id is gone.
- **2.6 export presets** — `ExportPresets.swift` + `ExportSheet.swift` replace the
  flat USDZ/OBJ/STL/GLB/PLY/CSV `confirmationDialog` with intent rows ("Share in
  AR", "Open anywhere", "3D print it", "Raw point data"…) each carrying an
  estimated size. The texture half of the estimate is **exact** (atlas pages are
  already-encoded `Data`); geometry is a per-container bytes-per-vertex model.
- **1.5 Liquid Glass** — `glassPanel` (every panel in the app routes through it)
  now uses native `.glassEffect(.regular, in:)` under `#available(iOS 26, *)`,
  `.ultraThinMaterial` + hairline below. New `glassGroup(spacing:)` wraps sibling
  panels in a `GlassEffectContainer` (applied on the home screen).
- **2.4 first-run onboarding + permission priming** — `App/OnboardingView.swift`,
  three pages (what it is / how to scan well / on-device privacy), shown once on
  `AppSettings.hasSeenOnboarding` and replayable from Settings ▸ About ▸ Welcome
  tour. The last page's button calls `AVCaptureDevice.requestAccess` — until now
  ARKit raised the camera prompt **cold** inside a capture mode, where a denial is
  effectively unrecoverable in-app. The tour is raised from `RootView`; the replay
  path fires on the settings sheet's `onDismiss` so the full-screen cover can't
  race the sheet's own dismissal.
- **2.8 Studio redo + CSG detail tier** — closes 2.8. `ModelStudioViewModel` gained
  a `redoStack` (depth 8, same as undo): `pushUndo` clears it (a new edit forks the
  timeline — otherwise Redo pastes an abandoned branch over fresh work), `undo`
  pushes the current stage onto it, `redo` steps forward; both stacks are shed
  under memory pressure, redo first as the more expendable half. `MeshBoolean.Detail`
  (Fast 64 / Standard 96 / Fine 160 cells) replaces the hard-coded 96 — a boolean
  *resamples* both inputs, so that constant was the detail ceiling and was visibly
  softening scanned models pushed through a carve. Persisted (`Settings ▸ Model
  Studio ▸ Boolean detail`), read off-main via `StudioSettings`, and **Standard is
  still 96** so existing installs get byte-identical results.
- **Control Center / Action button** (Tier 4, pulled forward) —
  `MagicCameraWidget/ScanControlWidget.swift` adds two iOS 18 `ControlWidget`s
  ("Start Scan", "Scan Gallery"). They use the system `OpenURLIntent` against the
  existing `magiccamera://` deep links rather than a custom intent, so there is
  nothing to keep in sync across the target boundary. Guarded `@available(iOS 18)`
  inside the `WidgetBundle` builder — the deployment target stays iOS 17.
- **First VM-level tests** (Tier 3's opener) —
  `Tests/MagicCameraTests/ModelStudioHistoryTests.swift`: the Studio undo/redo
  timeline (including the fork invariant and the memory-pressure shed), the widget
  ⇄ app deep-link round trip (ids are file names, so percent-encoding is the part
  that actually breaks), and the CSG tier ordering.
- **1.3 Dynamic Type / 1.4 VoiceOver** — new `cameraSurfaceTypeSize()` clamps the
  four camera surfaces (Spatial Scan, Live Depth, Object Capture, Room Plan) at
  `accessibility1`; they float over a viewfinder and cannot reflow. Everything
  else stays unclamped. Fixed-size chips (`EffectPicker`) and glyphs now use
  `@ScaledMetric` / semantic fonts; home cards use `@ScaledMetric` chips and
  collapse to one column at accessibility sizes. Added the missing LiveDepth
  labels (measure undo, and On/Off values on the detect/read/measure toggles) and
  lifted the sub-AA `white.opacity(0.82)` caption to 0.95.

---

## 0. TL;DR

Magic Camera is a LiDAR room/object scanner: capture a point cloud → reconstruct
a textured surface → view / measure / edit / export (USDZ, GLB, PLY, web) and a
Model Studio. It is **close to submittable**. Since the July-24 audit, all the
config-level ship blockers are done; the remaining gate is **device
verification** (the user's job — needs the physical iPhone) plus **one code
blocker: a memory-pressure governor**. The scan/texture quality had three fixes
this session (r65–r67) that are **built, green, pushed, but NOT device-verified.**

**The single most important operational fact is in §1 — the build directory
trap. Get that wrong and you waste the session shipping onto a dead branch.**

---

## 1. ⚠️ Branch & build situation — READ BEFORE ANYTHING

- **Canonical branch:** `claude/cloud-mesh-postprocess-optimize-8cb455`
  in worktree
  `/Users/keks/Developer/Magic-camera/.claude/worktrees/cloud-mesh-postprocess-optimize-8cb455`.
  HEAD `ca170a2` (2026-07-25). **This is the branch to build and commit on.**
- **The trap:** the *main* working dir `/Users/keks/Developer/Magic-camera` has
  twice been checked out to a STALE branch, and the user built it and saw an
  ancient UX (the removed Point/Mesh mode picker). It is **not** where the latest
  work lives. Always run, before telling the user to build anything:
  ```
  git -C <dir> log --oneline -1
  ```
  and confirm it matches the canonical HEAD. Hand the user an **explicit
  worktree path**, never just "build the project".
- **Relationship to main:** the canonical branch is **12 commits ahead of
  `origin/main`** (`2d5c7a4`) and strictly supersedes it — `origin/main`'s content
  equals commit `c096dac`, an ancestor. So nothing on `main` is newer. The r60–r67
  work (ICP, keyframe batching, area-lattice, iCloud/widget, multi-page atlas,
  lattice fix, cost cap) lives only on the branch and has **not been PR'd to main
  yet.** Opening that PR is a discrete task when the user wants it.
- **Mesh mode is gone by design** (commit `8e60f50`, unified Room/Object flow). A
  build showing a Point/Mesh picker is *stale*, not a regression. `ScanKind` still
  exists internally. Do not "restore" it without asking.
- **Build discipline:** `xcodegen generate` after adding/removing files (the
  generated `project.pbxproj` IS committed — keep it in sync). Batch edits, build
  once at the end with `xcodebuild build` against the worktree's `.xcodeproj`;
  don't run the test target unless asked (device build for real signing needs the
  worktree path or signing fails). The shell CWD resets between commands on this
  project — use `git -C` + absolute paths.

---

## 2. What shipped this session (r65–r67) — build-green, NOT device-verified

Full per-round detail is in project memory `scan-quality-session-2026-06.md`
(rounds r65/r66/r67). Summary:

### r65 — Multi-page texture atlas (`83f2374`)
A baked colour atlas can now span several 8192² **pages** instead of one, which
was the top texture-quality lever. Measured on a **real** 119 m² device export:
1 page 1.94 mm/texel → 4 pages **0.97 mm/texel = 2.0× linear** (√N; the handoff's
"3.4×" estimate was wrong — no under-fill to recover). Objects stay single-page.
- Model: `TexturedMesh` now `textures: [Data]` + `pageOfTri` (single-page
  convenience init keeps all non-scan producers untouched).
- Atlas encoding moved **PNG → JPEG q0.92** (a 4-page PNG atlas would bloat every
  save/export); Studio palette atlas stays PNG. glTF mimeType is sniffed from
  magic bytes so pre-JPEG saved models still export.
- Codec `MeshStore` **v3** / `StageStore` **v3** (written only when actually
  paged; unpaged saves stay byte-identical v2; v1/v2 still load).
- Exporters: GLB = one primitive/material/image per page; SceneKit (viewer +
  USDZ) = one element per page. Studio carries pages through the merge baker.
- Pages render **sequentially** → peak memory is one sheet; paging costs bake
  TIME. `AtlasPage` off-canvas adapter lets every per-triangle pass render one
  page unchanged — except the seam leveller, which SAMPLES its corners and so took
  an explicit `page:` filter.

### r66 — Lattice fix: "surfaces have too few triangles" (`a6886be`)
The one-tap `makeQuickModel` throttled the reconstruction lattice to the cloud's
**mean** nn-spacing. A room's cloud is distance-coarsened (near walls ~12 mm, far
walls up to ~48 mm), so the mean was dragged up by the sparse far tail and
coarsened the WHOLE surface to ~45–55 mm cells — coarser than the 28 mm noise
floor, so the floor never engaged. Two same-size device rooms meshed **68k vs
295k triangles** on nothing but scan distance.
- Fix: surface clamp uses `BallPivotingMesher.spacingPercentile(0.35)` (the dense
  near bulk); objects keep the mean. Now the 28 mm floor actually binds →
  consistent triangle density ∝ area, ~2–3× more triangles.
- Backstops that make it safe: 28 mm floor = hard min cell (no sub-cm torn-paper),
  900k bake budget (no decimation cracks), `adaptiveSupport` keeps sparse far
  walls solid.
- Added the **`lattice — res N · cell X mm · floor 28 mm`** diagnostic — the cell
  size was missing from every prior triangle-density diagnosis.

### r67 — Bake cost cap: fix the watchdog crash on huge scans (`ca170a2`)
A 2.26M-point room reconstructed (post-r66) to 205k triangles, baked over 78
keyframes × 4 pages, ran ~90 s of CPU and iOS **killed the app mid-bake** (user
got only the point cloud). The r65 multi-page bake re-runs the keyframe stream +
parallel CPU passes **per page**, and r66's finer mesh (~2× triangles) compounded
it: cost ≈ tris × keyframes × pages.
- Fix: `PhotoTextureBaker.affordablePageBudget` caps pages so `tris × keyframes ×
  pages ≤ bakeCostCeiling` (16M, calibrated to the bakes that finish). Big rooms
  drop to 1 page (~50 s, completes = pre-paging behaviour); small/medium rooms
  keep their pages. `bake budget — …` breadcrumb when it engages.

**User feedback on this build:** geometry "vypadá to lépe" (looks better — r66
confirmed), but "trvá dlouho než se dokončí postprocess" (slow) and the big scan
crashed (r67 addresses the crash; slowness is partly r66's 2× triangles).

---

## 3. Device-verification debt (the user's homework — needs the physical iPhone)

None of r65–r67 is device-verified. Priority checks, with the breadcrumb to read:

1. **Big room finishes** (r67): re-scan the 2.26M-point room → diagnostics show
   `bake budget … pages ≤ 1` and it **completes with a textured surface** (no
   relaunch). Watch the bake time.
2. **Triangle density** (r66): `lattice — cell ~28 mm` (not 45–55) and `object
   model — mesh N tris` up ~2–3× and **consistent** between similar rooms (not
   swinging 68k–295k). Walls stay solid (no far-wall confetti holes). If a wall
   holes, raise the percentile 0.35→0.5.
3. **Multi-page sharpness** (r65): a big room shows `pages 4 · ~0.97 mm/texel` and
   is visibly sharper; peak memory unchanged; USDZ/GLB/in-app viewer all show
   **every** page (a dropped page = untextured/black patches).
4. **Object Capture** (roadmap 0.2): never compiled in-sim — confirm it doesn't
   crash on entry on device.

---

## 4. Production-readiness plan (updated status)

Grades: **BLOCKER** (submission fails without it) · **REQUIRED** (credible 1.0) ·
**POLISH**. Effort XS/S/M/L. Built on [07-roadmap](07-roadmap.md); statuses
re-verified against HEAD `ca170a2` on 2026-07-25.

### Tier 0 — Ship blockers

| Item | Status (2026-07-25) | Grade | Effort |
|------|---------------------|-------|--------|
| Privacy manifest `PrivacyInfo.xcprivacy` (app + widget) | ✅ **DONE** — both targets, in pbxproj | BLOCKER | — |
| `ITSAppUsesNonExemptEncryption=false` + version 1.0.0 | ✅ **DONE** — Info.plist + project.yml | BLOCKER | — |
| Discard confirmation on "New" over an unsaved scan | ✅ likely done (`d546611` "discard guard") — **verify the dialog exists** | REQUIRED | XS |
| Widget staleness on delete | ✅ **DONE** — `delete()` republishes + reloads | REQUIRED | — |
| **Memory-pressure governor** | ✅ **DONE** (2026-07-25) — `MemoryPressureMonitor` + VM `respondToMemoryPressure`; **device-verify** the `.critical` cancel on a huge scan | BLOCKER | — |
| Device-verify Object Capture (0.2) | ⏳ user/device | BLOCKER | S |
| Device-verify scan/bake incl. r65–r67 (0.3) | ⏳ user/device | BLOCKER | S |
| App Store Connect record + first Archive (signing) | ⏳ user step | BLOCKER | S |
| Lock final app name + bundle id before the ASC record | ⏳ user decision | REQUIRED | XS |
| Screenshots (6.9"/6.5" iPhone + iPad), description, privacy label ("Data Not Collected") | ⏳ user/marketing | REQUIRED | M |

**All Tier-0 code work is DONE** (memory governor shipped 2026-07-25). Everything
else is config (done) or the user's device/ASC steps.

### Tier 1 — Best-in-class quality (the "wow")
- **1.1 Multi-page atlas** — ✅ **DONE** (r65). Just needs device verification (§3).
- **1.2 Scan-progress Live Activity / Dynamic Island** — ✅ **DONE** (2026-07-26).
  `ScanActivityAttributes` + `ScanLiveActivity` (widget) + `ScanLiveActivityController`
  (app), driven off a `phase` didSet + a 1.5 s count ticker. **Device-verify**:
  needs Live Activities enabled + iPhone 14 Pro+ for the Dynamic Island.
- **1.3 Dynamic Type hardening** — ✅ **DONE** (r70). `cameraSurfaceTypeSize()`
  clamp on the four camera surfaces; `@ScaledMetric` chips/glyphs; home grid
  collapses to one column at accessibility sizes.
- **1.4 VoiceOver labels** — ✅ **DONE** (r69 + r70): undo/redo, auto-orbit,
  quality-heatmap, Studio X/Y/Z steppers, and r70's LiveDepth measure-undo +
  On/Off values on the detect / read / measure toggles.
- **1.5 Native iOS 26 Liquid Glass** — ✅ **DONE** (r70). `glassPanel` branches on
  `#available(iOS 26, *)` to `.glassEffect`, `.ultraThinMaterial` below;
  `glassGroup(spacing:)` for sibling clusters.

### Tier 2 — Feature completeness & polish
- ✅ **App Intents** (Object Capture / Room Plan / Model Studio) — done 2026-07-26
  (`AppShortcuts.swift`, 5 shortcuts total).
- ✅ **Web-viewer CDN fail-loud** — done 2026-07-26 (offline export shows a clear
  message instead of a blank page).
- ✅ **Tier 2 is COMPLETE** as of 2026-07-27 (r70, see §0a): per-scan widget deep
  link (2.3), first-run onboarding + permission priming (2.4), home mode taxonomy
  (2.5), export presets with size hints (2.6), Studio redo + CSG detail tier (2.8).
- Open (not on the original list): the "not sure?" smart picker that pairs with
  onboarding, and an interactive "Finish scan" button on the Live Activity.

**See also [08-coherence-and-ideas](08-coherence-and-ideas.md)** — a product-level
review of whether the modes hang together. Its headline finding (the home-screen
taxonomy presented Spatial Scan / Object Capture / Room Plan as peers when they're
one intent with three engines) is **fixed** as of r70; the prioritised feature
ideas below it still stand.

### Tier 3 — Architecture hardening (opportunistic, not big-bang)
Unify the operation runner (adopt in Studio), decompose the ~large
`SpatialScanViewModel`, centralize scattered tuning constants into a typed
`ScanTuning`, split remaining 800+ LOC files, DI over singletons. ✅ **First
VM-level tests landed** (r70 — `ModelStudioHistoryTests`, covering the Studio
undo/redo timeline; the pattern to copy for the next VM). See
[07-roadmap §Tier 3](07-roadmap.md).

### Tier 4 — Differentiators (after 1.0)
On-device AI (FoundationModels: auto-name/describe scans, NL gallery search —
fits the "nothing leaves your device" story), first-class hand-off of small
objects to Object Capture, revisit the 28 mm geometry floor now ICP cut
registration noise ~16→2 mm (real-export-validated only), SceneKit→RealityKit
migration (XL — strategic, do NOT start until 1.0 is locked). ✅ **Control Widget
"Start scan" pulled forward and shipped** (r70 — plus a "Scan Gallery" control).

---

## 5. Recommended sequencing for the next chat

All Tier-0 code + the two "wow" items (multi-page atlas, Live Activity) are DONE.
The critical path is now **device verification**, then submission.

- **Round A — submittable (user):** ASC record + first Archive (registers the
  iCloud container + App Group) + screenshots + privacy label ("Data Not
  Collected"). No code left here.
- **Round B — device round (user scans, then tune):** work the §3 checklist —
  big-room bake finishes, `lattice — cell ~28 mm`, multi-page sharpness, the
  Live Activity in the Dynamic Island, the `.critical` memory cancel. Tune
  (percentile, `bakeCostCeiling`, and — flagged — the 28 mm floor) only against
  real exports.
- **Round C — premium feel:** ✅ **DONE** (r70). All of Tier 1 and all of Tier 2
  landed: Dynamic Type (1.3), VoiceOver (1.4), Liquid Glass (1.5), per-scan deep
  link (2.3), onboarding (2.4), home taxonomy (2.5), export presets (2.6), Studio
  redo + CSG tier (2.8), plus the Control Center widgets and the first VM-level
  tests. **There is no remaining ship-blocking code work.**
- **Round D — verify r70's confidence grading on device** (§0a) before tuning
  anything else in the scan pipeline. It changes what enters the cloud, so it
  sits upstream of every other quality lever.
- **Round E — what's left is Tier 3 and Tier 4**, neither of which blocks 1.0.
  The natural next step in Tier 3 is `ScanTuning` (the scan constants are scattered
  across `CaptureQuality`, `ScanConfig`, `DepthSampleConfidence` and the
  reconstruction path, which makes device tuning rounds slower than they need to
  be) — but do it **after** the device round, so the numbers being centralised are
  the numbers that survived verification.

---

## 6. Cross-cutting laws (hard-won — violating these has burned the project)

- **Validate any atlas/geometry change against REAL device exports, never
  synthetics** — this has produced false results 4×. Real `.mcmesh`/`.usdz`/`.ply`
  exports live in the sibling worktree `.claude/worktrees/eloquent-euclid-2d4bd4`
  and the user's iCloud (`~/Library/Mobile Documents/iCloud~com~keks~MagicCamera`).
  When compiling a shipping type standalone, **dedupe double-sided faces first**.
- Geometry detail floor is ~cm (LiDAR depth noise); **detail lives in the
  TEXTURE**, not the lattice. Don't chase sub-cm geometry.
- The bake is expensive and roughly `tris × keyframes × pages`; any change that
  raises triangle count or pages must respect `bakeCostCeiling` / the CPU
  watchdog. Big scans (2–3M points) are the stress case.
- Diagnostics are the instrument: Settings ▸ Diagnostics exports the breadcrumb
  log + MetricKit. Add a breadcrumb before tuning blind (r66's `lattice` line is
  why we could diagnose the crash).

---

## 7. Code review of r65–r67 — risk map

Reviewed against HEAD `ca170a2`. Each area marked ✅ verified-safe (by unit test
and/or code structure) or ⚠️ device-verify (correct by design, but only a real
export/render proves it). Tests live in `Tests/MagicCameraTests/`
(`MultiPageAtlasTests`, `GPUTextureBakerTests`, `ReconstructionTests`).

- ✅ **Codec round-trip (MeshStore v3 / StageStore v3).** `MultiPageAtlasTests`
  covers paged save→reload (every page + page map survives, in order), unpaged
  save stays **v2 byte-identical**, and v3 only appears when actually paged. v1/v2
  still load (bounds-guarded `readU32` helpers, `loadUnaligned` throughout,
  `pageCount ≤ 64` and `mapCount == indexCount/3` guards). Low risk.
- ✅ **Page partition.** `trianglesByPage()` / `pageOfVertex()` map every triangle
  to exactly one page; the exporters emit one primitive/element per non-empty
  page; a triangle's page is clamped to `pageCount-1`. Tested (partition covers
  0..<triCount once).
- ✅ **AtlasPage vs seam-leveller.** The one genuinely subtle invariant: every
  per-triangle pass that only WRITES (fallback paint, texel repair, de-light)
  renders one page via the off-canvas `AtlasPage` mask; the seam leveller SAMPLES
  its corners, so it takes an explicit `page:` filter on the FULL layout instead.
  `testAtlasPageVisitsOnlyItsOwnTriangles` pins the mask. Confirmed no sampling
  pass receives an AtlasPage.
- ✅ **Sequential page memory.** The bake loop renders → post-processes → encodes
  → releases each page before allocating the next; peak stays one 8192² sheet.
  `bakeCostCeiling` bounds total time. Cost arithmetic (`tris × keyframes`) is
  safe in 64-bit Int (worst realistic ~1e9, no overflow); `max(1, …)` floor.
- ✅ **spacingPercentile edges.** Empty / single-point cloud → nil (the
  `points.count ≥ 2` guard in `sampledNeighbourDistances`); percentile clamped to
  [0,1]; index clamped to the array. `meanSpacing` refactor is byte-identical
  (tested on the uniform grid).
- ⚠️ **Multi-page exports on a real device.** GLB (per-page primitives sharing one
  POSITION/NORMAL/TEXCOORD_0 accessor set) and USDZ/SceneKit (per-page elements)
  are correct glTF/SceneKit by construction and unit-tested for structure, but
  **only opening a paged export in AR Quick Look / a glTF viewer proves every page
  renders.** A dropped/misindexed page shows as untextured/black patches. On the
  §3 device round, export a paged room to USDZ **and** GLB and eyeball all pages.
- ⚠️ **Studio paged import.** `ModelStudioBaker` gives each `(object, page)` its
  own grid cell and `colorCloud` decodes one page at a time — the most intricate
  new code. Tested, but device-verify a paged room imported to the Studio stage
  and re-baked.
- ⚠️ **JPEG q0.92 atlas.** Lossy; photographic content shouldn't ring, but confirm
  no visible block artefacts on a high-detail wall on device. (Studio palette
  atlas correctly stays PNG.)

No CRITICAL/HIGH correctness defect found in the diff. The residual risk is
render-fidelity on device (the ⚠️ items), which is exactly what §3 covers.

## 8. Crash-safety & memory-pressure — the remaining code blocker

### 8.1 Memory-pressure governor — ✅ SHIPPED (2026-07-25)
Was the last Tier-0 code blocker; now implemented.
- `MagicCamera/Core/MemoryPressureMonitor.swift` — `@MainActor` singleton wrapping
  `DispatchSource.makeMemoryPressureSource([.warning, .critical], queue: .main)`,
  started once in `RootView.task`. Handler is `@Sendable` + `MainActor.assumeIsolated`
  (avoids the known GCD/MainActor `setEventHandler` SIGTRAP). It logs a `memory
  pressure` breadcrumb (telemetry either way), purges `URLCache.shared`, and posts
  `.memoryPressure`. `simulate(_:)` drives the same path for tests; `level(for:)`
  is `nonisolated` and pure (critical wins when both bits set).
- `SpatialScanView` subscribes via `.onReceive` → `SpatialScanViewModel.respondToMemoryPressure`:
  **`.warning`** sheds undo/redo to the most recent step; **`.critical`** sheds all
  history and, if `isBusy`, calls the existing `cancelHeavyWork()` + toasts "Low
  memory — stopped processing". Turns a silent jetsam kill into a recoverable stop
  (last state is autosaved; the "Recover unsaved scan?" alert already exists).
- Tests in `MemoryPressureMonitorTests` (critical-wins mapping, broadcast, idle
  no-op). **Device-verify** the `.critical` cancel actually fires on a 2–3M-point
  scan (simulate memory pressure via Instruments / the Simulator's memory-warning).
- ✅ **Studio follow-up DONE (2026-07-26):** `ModelStudioViewModel` now observes
  `.memoryPressure` and sheds its undo history (`.warning` keeps the newest step,
  `.critical` drops all). Studio ops share no cancel token, so an in-flight Studio
  bake isn't interrupted — undo shedding is the lever there; the stage is autosaved.

### 8.2 Cancellation gaps — ✅ ADDRESSED (2026-07-26)
The r67 crash was a CPU-watchdog kill; the residual risk was a **screen-lock
mid-bake → background kill** because the two heavy passes never checked
`Task.isCancelled` mid-loop. Both now take an `isCancelled` closure:
- `TextureSeamLeveler.level` — checked per Gauss-Seidel iteration (40–160 total).
- `TextureAtlas.fillGutters` — checked every ~65 k texels of the BFS flood.
All 8 `PhotoTextureBaker` call sites pass `{ Task.isCancelled }`; the default is a
no-op so other callers/tests are unchanged. A backgrounded or memory-shed bake now
bails within a fraction of a second instead of running 10–20 s past the request.
(Remaining minor gap: the parallel `concurrentPerform` per-triangle passes still
run to completion, but those are bounded and far shorter than the two fixed here.)

### 8.3 OOM risks on 2–3M-point scans — mostly bounded, watch these
- ✅ Undo stack is bounded (`maxUndoDepth = 8`, `undoMemoryBudget = 250 MB`, evicts
  oldest). Not the culprit.
- ✅ Atlas buffers are now sequential (r65); reconstruction band is bounded
  (`bandLimited` → ≤2.5M cells). 
- ⚠️ Peak is the reconstruction of a 3M-point cloud held alongside its source copy
  + keyframe JPEGs (up to 96 × ~1–2 MB) + the working mesh. No hard ceiling on the
  *sum*; 8.1's `.critical` cancel is the intended backstop. A 3M cap exists for
  capture (`roomConfig`), but the review-time peak is unmodelled — the governor is
  the right fix rather than more point caps.

### 8.4 runOperation robustness — acceptable
Autosave is growth-gated (guards the historical 4.3 GB / diskWrite-exception
problem); a mid-op kill leaves the last checkpoint, recovered via the
"Recover unsaved scan?" alert. `runOperation` uses `beginOperation`/`endOperation`
+ a `workGeneration` stale-guard so a superseded/orphaned Task can't clobber
newer state or wedge the spinner. No action needed beyond 8.1/8.2.
