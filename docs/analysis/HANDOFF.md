# HANDOFF — Magic Camera, next chat starts here

_Written 2026-07-25. Self-contained context + the plan to get to a submittable
1.0. Read this first, then the numbered `docs/analysis/*` for depth. Supersedes
the status tables in [06-appstore-readiness](06-appstore-readiness.md) and
[07-roadmap](07-roadmap.md) where they disagree — several items have since
shipped._

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
| **Memory-pressure governor** | ❌ **STILL MISSING** — no `DispatchSource` memory source / `didReceiveMemoryWarning`. Open-loop OOM = jetsam risk on 2–3M-point scans | BLOCKER | M |
| Device-verify Object Capture (0.2) | ⏳ user/device | BLOCKER | S |
| Device-verify scan/bake incl. r65–r67 (0.3) | ⏳ user/device | BLOCKER | S |
| App Store Connect record + first Archive (signing) | ⏳ user step | BLOCKER | S |
| Lock final app name + bundle id before the ASC record | ⏳ user decision | REQUIRED | XS |
| Screenshots (6.9"/6.5" iPhone + iPad), description, privacy label ("Data Not Collected") | ⏳ user/marketing | REQUIRED | M |

**Remaining Tier-0 code work is essentially one item: the memory-pressure
governor.** Everything else is config (done) or the user's device/ASC steps.

### Tier 1 — Best-in-class quality (the "wow")
- **1.1 Multi-page atlas** — ✅ **DONE** (r65). Just needs device verification (§3).
- **1.2 Scan-progress Live Activity / Dynamic Island** — the user's explicit ask;
  the progress hook + operation host already exist. **M.** Biggest remaining
  user-visible feature.
- **1.3 Dynamic Type hardening** on the custom camera surfaces — **M.**
- **1.4 Missing VoiceOver labels** (undo/redo, auto-orbit, measure, Studio
  steppers) — **S.**
- **1.5 Native iOS 26 Liquid Glass** on primary chrome behind `#available`,
  `glassPanel` fallback — **M.** (A `liquid-glass-design` skill exists.)

### Tier 2 — Feature completeness & polish
App Intents (Object Capture / Room Plan / Studio), per-scan widget deep link
(`magiccamera://scan/<id>`), first-run onboarding + permission priming, export
sheet redesign with size hints, web-viewer CDN fail-loud, Studio redo. See
[07-roadmap §Tier 2](07-roadmap.md). Mostly S/M.

### Tier 3 — Architecture hardening (opportunistic, not big-bang)
Unify the operation runner (adopt in Studio), decompose the ~large
`SpatialScanViewModel`, centralize scattered tuning constants into a typed
`ScanTuning`, split remaining 800+ LOC files, DI over singletons + first
VM-level tests. See [07-roadmap §Tier 3](07-roadmap.md).

### Tier 4 — Differentiators (after 1.0)
On-device AI (FoundationModels: auto-name/describe scans, NL gallery search —
fits the "nothing leaves your device" story), first-class hand-off of small
objects to Object Capture, revisit the 28 mm geometry floor now ICP cut
registration noise ~16→2 mm (real-export-validated only), Control Widget "Start
scan", SceneKit→RealityKit migration (XL — strategic, do NOT start until 1.0 is
locked).

---

## 5. Recommended sequencing for the next chat

- **Round A — submittable:** the memory-pressure governor (the one code blocker)
  + verify the discard dialog + confirm the device-verification checklist with the
  user. Then it's ASC record + Archive + screenshots (user steps). *This is the
  shortest path to "can submit".*
- **Round B — device round on r65–r67:** the user scans; read the breadcrumbs in
  §3; tune (percentile, `bakeCostCeiling`, and — flagged — the 28 mm floor) only
  against real exports.
- **Round C — the wow:** Live Activity / Dynamic Island (1.2) — the user's ask.
- **Round D — premium feel:** accessibility (1.3/1.4) + Liquid Glass (1.5).

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

### 8.1 Memory-pressure governor — MISSING (Tier-0 BLOCKER)
Confirmed: **no** `DispatchSource.makeMemoryPressureSource`,
`didReceiveMemoryWarning`, or memory-warning handling anywhere. Processing is
open-loop, so a 2–3M-point scan that approaches the jetsam limit gets killed with
no chance to shed. Minimal concrete design:

- A small `MemoryPressureMonitor` wrapping
  `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
  queue: .main)`, started once (RootView `.task`, next to `CloudStore.shared.start()`).
- On **`.warning`**: shed recoverable memory — collapse the undo stack to depth 1
  (`undoStack`/`redoStack` in `SpatialScanViewModel`, already budgeted), drop the
  thumbnail/decoded-photo caches.
- On **`.critical`**: cancel the in-flight heavy operation through the existing
  runner (`runOperation`'s cancellable `Task.detached` + `workGeneration`
  stale-guard — see the operation-runner pattern), shed the undo stack entirely,
  and toast "Low memory — stopped processing". This turns a silent jetsam kill
  into a graceful, recoverable stop (the "Recover unsaved scan?" alert already
  exists on relaunch).
- Effort **M**. It reuses the cancellation machinery already there; the new code
  is the source + the two handlers.

### 8.2 Cancellation gaps — long passes can't be interrupted (feeds the crash)
The r67 crash was a CPU-watchdog kill; the residual risk after the cost cap is a
**screen-lock mid-bake → background kill**, because two heavy passes never check
`Task.isCancelled` mid-loop (grep-confirmed, 0 checks each):
- `TextureSeamLeveler.level` — Gauss-Seidel, 40–160 iterations over up to 600k
  triangles. Can run **10–20 s** with no cancel check.
- `TextureAtlas.fillGutters` — a full 8192² (67 M-texel) BFS flood, per page.
Between them, a bake can run well past iOS's few-second background grace period
after `handleEnterBackground` requests cancellation → killed. **Fix:** thread a
lightweight `isCancelled` closure into both and check it every N rows/iterations
(cheap, no behaviour change when not cancelled). This is the direct follow-up to
r67 and pairs with 8.1.

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
