# 02 · Spatial Scan Pipeline

_Scope: `MagicCamera/SpatialScan/` (87 files, ~25k LOC). Worktree HEAD `e20dbfb`._

> **Update 2026-07-27 (r70) — ingest confidence.** Every hard gate described below
> still exists and is unchanged, but a sample that clears them no longer enters at
> full ARKit confidence: it carries a **graded** score (silhouette proximity,
> grazing incidence, range, radius in frame, camera motion) and is rejected only
> when several of those signals agree. See
> `MagicCamera/SpatialScan/DepthSampleConfidence.swift` and
> [HANDOFF §0a](HANDOFF.md). Kill switch: Settings ▸ Sample confidence.

**Verdict:** research-grade mobile 3D reconstruction, well past typical LiDAR-app
quality. The core algorithms — frame-to-model ICP, TSDF fusion with ray-carving,
Hoppe signed-field reconstruction, searched-gate UV unwrap — are correctly
implemented and battle-tested against real device scans (the r10–r64 series in
memory). Main risks are structural (a few enormous files), two known quality
ceilings (texture density, geometry detail floor), and heavy reliance on Swift-6
concurrency escape hatches.

## End-to-end data flow

```
ARFrame (LiDAR sceneDepth + confidence + capturedImage + optional sceneMesh/planes)
   │  ScanARView (coordinator) → ScanRecorder.process(frame:)
   ▼
CAPTURE — ScanRecorder._process (ScanRecorder.swift:1017)
   • backpressure gate (≤2 frames in flight)
   • keyframe consideration (photo+pose+depth) → ScanKeyframeRecorder
   • adaptive frame stride (confidence-scaled) + steadiness gate (anti-blur)
   • GPU unproject → dedup → candidates  (ScanComputeUnprojector; CPU fallback)
   • FrameToModelICP.refineRegistration (per-frame pose correction)
   • crop tests (ROI sphere / silhouette / support plane) → adaptiveSnap
     → carveFreeSpace → fuse (TSDF running mean)
   • chunked capture: seal at cap, continue in same world frame (≤4 chunks)
   ▼
FINISH — SpatialScanViewModel.stopScan (:980, off-main)
   • snapshotDenoised (voxel-neighbour prefilter)
   • PointCloudVisibilityFilter.trim (multi-view see-through consensus)
   • branch: Room→auto Build Surface · Object→cloud review · Mesh→reconstruct
   • ScanAutoSave (crash recovery)
   ▼
RECONSTRUCT — ReconstructionPipeline (shared spine, reconstructMesh / makeQuickModel)
   • cloud: dropLowConfidence → bilateralDenoise → subsample(density)
            → curvaturePrepass → removeOutliersAndStrays
   • densityResolution sizes lattice by AREA (+28mm room noise floor)
   • method: voxel / smooth+fusion (Hoppe field + MarchingCubes, GPU+CPU gate) / ballPivot
   • mesh: small-component + long-edge + pinhole fill + erode → cleanup
           → plane snap → cloud snap → ghost trim
   ▼
TEXTURE BAKE — PhotoTextureBaker.bake (:71)
   • keyframe select (sharpest ≤96 pose-diverse)
   • Pass1 best-view per triangle (occlusion-tested) → Pass1.5 view smoothing
   • ChartAtlas UV unwrap (gate search) → AreaProportional → per-triangle
   • Pass2 GPU multi-view blend (batched, running weighted mean, exposure gain)
   ▼
SAVE / EXPORT — ScanStore/MeshStore · GLB(hand glTF) · USDZ(SceneKit) · OBJ/STL · PLY · web(three.js) · floor-plan PDF
```

The architectural win is **`ReconstructionPipeline`** (`ReconstructionPipeline.swift:27`),
a value struct unifying the cloud→surface spine that Build-Surface and one-tap
model used to duplicate — the header documents three rounds where a fix once
landed in only one of the two copies.

## Key stages & knobs

- **Config** — `ScanConfig` (`ScanRecorder.swift:13`) is the master struct, driven
  by `ScanQuality` (Fast/Balanced/Detailed/Ultra) and `CaptureQuality`
  (Draft/Balanced/Max/Object/Room, `CaptureQuality.swift:98`). Room: 12 mm voxel,
  3 M cap, 7 m depth, `carveStrength 1.0`, `edgeThreshold 0.12`. Object: 3 mm
  (2 mm fine), 1.5 m range, steadiness gate, scene-mesh mask.
- **GPU unprojection** — `ScanComputeUnprojector.unproject` (kernel + open-address
  voxel dedup); hard **65 536 points/frame** buffer cap.
- **TSDF fusion** — `fuse` (`:1682`) confidence-weighted running mean per voxel
  (weight cap 48); **`carveFreeSpace`** (`:1314`) ray-marches camera→hit and drains
  empty-corridor voxels with a voxel-scaled protective shell; scene-consensus rule
  `carves≥5 && seen≤3 && carves≥3×seen` kills bleed while protecting thin geometry.
- **Frame-to-model ICP** — `refineRegistration` (`:1433`): ROI-aware sampling,
  point-to-plane damped Gauss-Newton toward the ARKit prior, gates
  `translation≤2cm, rotation≤1°, rms non-increasing`; runaway guard measured **at
  the data** via `FrameToModelICP.drag` (the r60 lever-arm fix).
- **densityResolution** (`+Editing.swift:115`) — sizes the lattice cell from
  bounding-box **area** (`cell=√(2A/T)`), bounded by point-spacing, triangle
  budget, a 2.5 M band ceiling, and a **28 mm room noise floor** by scan type (r64).
- **SmoothSurfaceReconstructor** — a **Hoppe local-plane signed field** (not a true
  Poisson solve, despite the "Poisson-style" hint), evaluated on GPU and **gated by
  a 64-corner CPU spot-check** so a kernel slip can't ship.
- **Texture bake** — sharpest ≤96 pose-diverse keyframes; `ChartAtlas` UV unwrap via
  a **searched growth gate** (no mesh-specific tuned constant); GPU multi-view blend
  streamed in batches (r61) with per-view exposure harmonisation, seam leveling,
  gutter fill, ghost-sheet trim.
- **Post-process** — Manhattan-world plane lock, MLS cloud-snap, primitive/shape
  snap (relief-preserving), visibility trim. `MeshLouverSnap` is present but
  **deliberately disabled** (`+Editing.swift:365`) — it false-fired on the MC lattice.

## Strengths

1. **Frame-to-model ICP is textbook-correct** (point-to-plane Gauss-Newton,
   centroid-conditioned, Tikhonov-damped toward the ARKit prior, lever-arm-free
   reporting) — a root-cause fix for wall crinkle/drift, not a band-aid.
2. **Unified reconstruction spine** eliminates "fixed in one path only" bugs.
3. **Defensive GPU strategy** — every GPU path has a CPU fallback and the signed
   field is CPU-validated before use; GPU failures degrade, never corrupt.
4. **Watchdog discipline** — density subsampling, triangle budgets, frame
   backpressure, bounded carve steps, cadence-scaled autosave. The 90 s
   `cpu_resource` watchdog has clearly been fought and beaten.
5. **Clean hygiene for its size** — 0 `print()`, 0 `try!`/`fatalError`/`as!`; 33
   test files over the pure value-math core; nearly every magic number carries its
   device-measured justification.

## Limitations, risks, tech debt

**Quality ceilings (known, documented):**
- **Texture blur on large rooms is the #1 ceiling.** Single-page atlas density is
  pure area accounting: a 142 m² room in an 8192² atlas is bounded at **~1.8 mm/
  texel even with a perfect unwrap** (`ChartAtlas.swift:291`). The **multi-page
  atlas is fully built but not activated** — all `ChartAtlas.build` call sites use
  `maxPages: 1`. Highest-leverage dormant lever in the codebase.
- **Geometry detail floor ≈ 28 mm for rooms** — correct given LiDAR range-noise,
  but it pushes sub-cm room detail into the texture, compounding the texture
  ceiling. ICP has cut registration noise ~16→~2 mm, so this floor is a revisit
  candidate (real scans only).

**Structural:**
- **Seven files exceed the 800-LOC limit**: `ScanRecorder` (1945),
  `SpatialScanViewModel+Editing` (1731), `SpatialScanViewModel` (1446),
  `ScanARView` (1051), `SpatialScanView` (964), `SpatialScanReviewTools` (933),
  `PhotoTextureBaker` (905). `ScanRecorder` alone carries 8 responsibilities in one
  `@unchecked Sendable` class.
- **`makeQuickModel`** (`+Editing.swift:392`) is a ~450-line closure with a 6-branch
  isolation decision tree — the least testable, highest-load code in the pipeline.
- **98 `UncheckedSendableBox` usages** — each justified, but a large surface where
  compiler concurrency guarantees are manually vouched for.

**Fragility traps:**
- Per-frame candidate cap 65 536 silently truncates (fine today; unguarded against
  finer depth sources).
- Two different "weld" notions: bit-exact dictionary weld (`MeshData.swift:216`,
  soup-only) vs. ChartAtlas's 0.1 mm quantised weld — a latent trap.
- `removingSmallComponents(minFraction: 0.05)` can delete a legitimately small
  detached object in a multi-object room (object scans lower it to 0.01).
- `.smooth` method labelled "Poisson-style" but is Hoppe signed-distance — a
  user-facing misnomer.

## Recommendations (prioritized)

- **P0 — Activate the multi-page atlas.** Machinery exists and is tested. Land in
  two stages (plumb `pageCount=1`, then pass `maxPages: 4`): a 142 m² room reaches
  ~0.9 mm/texel (3.4×), memory spent one page at a time. Pair with **JPEG atlas
  export** (currently PNG) so a 4-page 8192² atlas doesn't balloon file size. This
  is the single biggest quality win at low risk. (See [05-tech-currency](05-tech-currency.md) rank #1.)
- **P1 — Split the god-objects.** Extract `FusionGrid`, `ICPCorrector`,
  `CoverageTracker` from `ScanRecorder`; extract a testable `SubjectIsolator` from
  `makeQuickModel`. Highest-value maintainability work; unblocks unit-testing the
  two most bug-prone areas.
- **P2 — Revisit the 28 mm geometry floor** now that ICP cut noise to ~2 mm —
  behind a flag, validated on real device exports (torn-paper failure is
  catastrophic; use the real-export harness, never synthetics — a repeated memory lesson).
- **P3 — First-class "hand small objects to Object Capture (PhotogrammetrySession)"
  flow** — the code already tells users to use it for sub-cm subjects
  (`SpatialScanViewModel.swift:1129`); the framework is linked. It would beat LiDAR
  exactly where the pipeline is weakest.
- **P4 — Harden traps** — diagnostic when the 65 536 cap is hit; rename the
  bit-exact weld to `dedupingSoupVertices`; make `removingSmallComponents`
  scene-object-aware (absolute cm³/area threshold).
- **P5 — Correctness polish** — drop the "Poisson-style" misnomer; consider async
  GPU completion for the per-frame unprojector if profiling flags the capture-queue stall.

_See [07-roadmap](07-roadmap.md) for how these sequence against the UX and
App-Store work._
