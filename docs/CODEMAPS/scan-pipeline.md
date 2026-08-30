# scan-pipeline — capture → reconstruct → texture → export

One frame of LiDAR depth becomes a textured model through four stages. Each
stage has a budget, a breadcrumb and a way to refuse. **The pipeline is where
this app's quality lives; read this before changing any of it.**

The quality ladder that ranks the work (from `../analysis/VISION.md`), in the
order it binds: geometry is *where the thing is* → geometry is *complete* →
*nothing that mattered was deleted* → the texture is *photographed* → the model
is *small enough to share* → it *looks intentional*.

## Stage 1 — capture (`ScanRecorder`, 1.9k lines)

```
ARFrame (sceneDepth + confidence + capturedImage + optional sceneMesh/planes)
  → backpressure gate (≤2 frames in flight)
  → keyframe consideration (photo + pose + depth)      → ScanKeyframeStore
  → adaptive frame stride (confidence-scaled) + steadiness gate (anti-blur)
  → GPU unproject + dedup (ScanComputeUnprojector; CPU fallback)
  → FrameToModelICP.refineRegistration                  (per-frame pose fix)
  → crop tests (ROI sphere / silhouette / support plane)
  → adaptiveSnap → carveFreeSpace → fuse (TSDF running mean)
  → chunked capture: seal at cap, continue in the same world frame
```

**Every knob is in `ScanConfig`, each with the reason it has that value.**
`CaptureQuality` maps the user-facing tiers (Draft / Balanced / Max / Object /
Room) onto it — reach for the tier, not the field.

Things that have bitten, and now carry guards:

* **`adaptiveSnap` is a budget guard, not a quality policy.** Run
  unconditionally it stamps concentric shells of lattice-frozen points around
  wherever the phone stood — the "radar rings" report, 31% of a room's points
  frozen, holes no amount of resweeping could fill. It is now gated on real
  pressure (`adaptiveVoxelPressureFraction`, 0.6 of the cap) and reports
  `snapped N`.
* **Sample confidence is graded, not binary.** `DepthSampleConfidence` scores
  each sample on silhouette proximity, grazing incidence, range, radius in
  frame and camera motion, and multiplies its confidence by the result. Fusion
  weights by that number, so bleed dies of neglect. **A sample is rejected only
  when several signals agree** — that is a test, not a convention.
* **ICP is gated and its drag is measured at the data.** `translation ≤ 2 cm`,
  `rotation ≤ 1°`, rms non-increasing, damped toward the ARKit prior.
  `FrameToModelICP.leveled` removes accumulated roll/pitch and keeps yaw,
  because compounding tilt put a floor 2.78° off level and 12 cm warped.
* **`carveFreeSpace`** ray-marches camera→hit and drains empty corridors, with a
  voxel-scaled protective shell and a consensus rule that kills bleed while
  protecting thin geometry. Strength is per-profile (`carveStrength`).
* **Object scans capture the ARKit scene mesh as a `SurfaceMask` crop.**
  `reconstructMesh` is deliberately unmasked.

## Stage 2 — finish and reconstruct (`ReconstructionPipeline`)

The **shared spine** for Build-Surface and one-tap model. Its header records
three rounds where a fix landed in only one of two duplicated copies; do not
re-fork it.

```
cloud:  dropLowConfidence → bilateralDenoise → subsample(density)
        → curvature prepass → removeOutliers / strays
lattice: densityResolution sizes the cell from bounding-box AREA (cell = √(2A/T)),
        bounded by point spacing, triangle budget, a band ceiling and a
        device-measured room noise floor (Object never inherits the floor)
method: voxel · smooth+fusion (Hoppe signed field + MarchingCubes, GPU with a
        64-corner CPU spot-check) · ballPivot
mesh:   small-component + long-edge trim → pinhole fill → erode → cleanup
        → plane snap → cloud snap → ghost trim
```

**Refusals that matter here:** `SurfaceMask.maskToSurface` returns nil rather
than gutting the cloud; the planar regulariser will not flatten a subject
(Object scans must report `surface cleanup — planes 0`); the unreliable-point
bar is the grading's own doubtful mark, so a bad scan is *thinned*, never
gutted.

**Variable-resolution reconstruction is built but not wired.**
`AdaptiveOctree.partition`, `AdaptiveMesher` (per-level marching cubes) and
`AreaProportionalAtlas` all exist, are tested, and are isolated from the live
uniform path. Wiring them is a device-proven job behind a flag — the live path
must not be swapped until then. `adaptiveDecimate` was dropped: it blurred walls.

## Stage 3 — texture bake (`PhotoTextureBaker`, 1.2k lines)

```
keyframe select (sharpest, ≤96, pose-diverse; KeyframeSharpness.weights)
  → Pass 1   best view per triangle, occlusion-tested
  → Pass 1.5 view-assignment smoothing
  → UV unwrap: ChartAtlas via a SEARCHED growth gate (no tuned constant)
               → AreaProportionalAtlas → per-triangle fallback
  → Pass 2   GPU multi-view blend, batched, running weighted mean,
             per-view exposure gain → seam level → gutter fill → ghost trim
```

**The budgets must be reconciled, and now are.** A room came back with 59% of
its texture *synthesised* rather than photographed because the triangle budget
and the atlas page budget were set independently:
`affordablePageBudget(triangleCount:keyframeCount:)` and
`affordableTriangleBudget(pages:)` are each other's inverse, and a test pins the
device room that came out mush.

**Do not raise `GPUTextureBaker.slicePixels`** — it multiplies by keyframe count
and OOMs. The levers that work are the per-triangle atlas `texSize` cap and
keyframe JPEG quality. `batchSize` / `sliceSize` exist to keep the blend inside
memory; they are decisions, not plumbing.

**Multi-page atlas packing is built and dormant** (`c096dac`, "built, not yet
activated").

## Stage 4 — save and export

| Target | Writer | Trap |
|---|---|---|
| `.mcscan` point cloud | `ScanStore` | compact binary, optional view directions |
| `.mcmesh` | `MeshStore` | carries the textured variant |
| USDZ | `SCNScene.write` | **ModelIO's USDZ is rejected by AR Quick Look** |
| GLB | `MeshGLBExporter` / `TexturedMeshExporter` | hand-written glTF |
| OBJ · STL | `MeshExporter` (ModelIO) | wrap off-main ModelIO in `autoreleasepool` |
| PLY | `PointCloudExporter` | binary LE and ASCII |
| web | `WebViewerExporter` | bundled offline three.js runtime |
| floor plan | `FloorPlanPDFExporter` | |

**Textured saves and USDZ are duplicated-corner soup — weld before any
connectivity operation.** `ExportPresets` estimates the byte cost of every
format up front so the sheet can show it before the user commits.

## Budgets and the watchdog

The 90 s CPU watchdog has been fought and beaten with: frame backpressure,
density subsampling, triangle budgets, bounded carve steps, cadence-scaled
autosave (`autosaveInterval`, `autosaveGrowthThreshold` — a growth gate that
stopped 4.3 GB of writes), a capped `SmoothSurfaceReconstructor` with
Int64-packed keys, and cancelling review-time work when the app backgrounds.

**Memory is still ungoverned.** The r88 room peaked at 3144 MB with 231 MB of
headroom and four critical-pressure events. It survived; nothing guarantees the
next one will.
