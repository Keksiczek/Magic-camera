# architecture — what talks to what

`MagicCamera/` is ~44k lines of Swift across ~180 files, plus a widget target.
Directories are features, not layers. The guiding rule from day one:
**acquisition is separate from rendering, and depth is never faked.**

```
App/          MagicCameraApp · RootView · AppRouter · Onboarding · AppShortcuts
Core/         device caps, math, Metal context, stores, settings, diagnostics
LiveDepth/    ARSession → Metal effect pass → photo / video / measure
SpatialScan/  the scanner: capture → reconstruct → texture → export  (~110 files)
Studio/       Model Studio: primitives, CSG, stage, on-device prompt engine
RoomPlan/     RoomPlan capture and its mesh bridge
ObjectCapture/ Apple Object Capture (guided photogrammetry)
Capabilities/ honest live report of what this device actually supports
UI/           Theme, controls, settings, storage manager, share sheet
Widget/       home-screen widget + Live Activity plumbing (App Group)
```

## Entry and routing

`MagicCameraApp` owns the scene, sweeps stale exports at launch and installs
the diagnostics hooks. `RootView` is the home surface; `AppRouter` carries
deep links and App Shortcuts into a mode. `OnboardingView` runs once.

`DeviceCapabilities` is the gate for every hardware-dependent screen —
`preferredDepthSemantics()` / `liveDepthSemantics()` decide what the AR session
may ask for, and a device without LiDAR gets `UnsupportedView`, never a
degraded scan.

## Mode 1 — Live Depth

```
ARSession ─(ARFrame)→ DepthEngine ─currentFrame→ MetalDepthView.Coordinator
                                                     │
                     EffectSettings (view model) ────┤
                                                     ▼
                                              EffectRenderer ──→ MTKView (preview)
                                                     ├──→ CGImage      (photo)
                                                     └──→ CVPixelBuffer (VideoRecorder → .mp4)

tap ──→ DepthSampler ──(depth + pose)──→ world point ──→ measure
```

`DepthEngine` owns the session and nothing else. `EffectRenderer` is one Metal
pipeline with one fullscreen pass and three entry points sharing an `encode`
path. `DepthEffectKind`'s raw values are pinned to the C `EffectType` enum in
`Shaders/ShaderTypes.h` by a unit test. Vision work (`SubjectMasker`,
`ObjectDetector`, `SubjectCutout`, `VisionGeometry`) feeds cutouts, measured
objects and the dimension exporter.

## Mode 2 — Spatial Scan

The bulk of the app. Full stage-by-stage detail is in
[scan-pipeline.md](scan-pipeline.md); the shape is:

```
ScanARView ─frame→ ScanRecorder ─→ PointCloud ─→ ReconstructionPipeline ─→ MeshData
   (ARKit)          (bg queue)                        (shared spine)          │
                                                                             ▼
                     ScanKeyframeStore ────────────→ PhotoTextureBaker ─→ TexturedMesh
                                                                             │
   ScanStore(.mcscan) · MeshStore(.mcmesh) · exporters (USDZ/GLB/OBJ/STL/PLY/web/PDF)
```

`SpatialScanViewModel` is the orchestrator and is split across six files by
concern — `+Reconstruction`, `+Cleanup`, `+Editing`, `+Export`, `+Intelligence`,
`+Lattice`. **The `nonisolated static func`s in those extensions are the
project's decision rules**; they are indexed in [policy.md](policy.md).

`ScanRecipe` is the user-visible plan: one ordered list of post-processing
steps, pre-filled per kind (Model / Surface), every step switchable by hand.
There is deliberately no separate "automatic path" — the buttons run the recipe
the disclosure is showing.

## Mode 3 — Model Studio

Standalone, no scan required. `ModelStudioViewModel` owns the stage;
`StudioPrimitives` meshes parametric shapes; `MeshBoolean` does voxel CSG
(signed-distance grids re-polygonised through `MarchingCubes`);
`ModelStudioBaker` bakes a stage down to one mesh plus an atlas;
`StageStore` persists `.mcstage`, `StudioAutoSave` snapshots it.

`ModelStudioEngine` is the on-device prompt engine (FoundationModels, iOS 26+):
the model emits **tool calls** into the deterministic stage operations and
never touches geometry itself. `ScanIntelligence` is the same idea on the scan
side — naming, scene description and the auto-fix plan.

## Cross-cutting

**Concurrency.** Swift 6 strict concurrency. View models are
`@MainActor @Observable`. Acquisition objects (`DepthEngine`, `ScanRecorder`,
AR coordinators) are plain classes that never touch main-actor state from a
background queue; shared state is lock-guarded. `Concurrency.swift` holds the
escape hatches, and every one of them is a place a Swift 6 trap can bite —
see `CLAUDE.md` §2.

**`OperationRunner`.** Every heavy review-time operation funnels through
`runOperation`: `beginOperation` / `endOperation`, a cancellable
`Task.detached`, and a `workGeneration` stale-guard so a superseded result is
reported and discarded rather than applied. Nine tests pin "completes exactly
once".

**Memory.** `MemoryPressureMonitor` maps the dispatch source's bits onto a
level and broadcasts it; the scan path reads it for autosave cadence and bake
budgets. There is **no governor yet** — see `CLAUDE.md` §0.

**Storage.** `FileStore` owns the directory layout and name sanitising.
`CloudStore` mirrors the library into the user's own iCloud container and can
migrate both ways. `ScanLibrary` is the single read surface the gallery, the
widget and the intelligence layer all go through.

**Diagnostics.** `Diagnostics.shared` is a rolling breadcrumb log plus captured
MetricKit payloads, exported from Settings as one file. It is the only channel
that survives a watchdog kill. See [diagnostics.md](diagnostics.md).

## Where things are NOT

* No server, no account, no upload. Every stage runs on the device.
* No mesh *scan kind* — a build showing a Point/Mesh picker is stale
  (removed in `8e60f50`); `ScanKind` still exists internally.
* No slat/louver regulariser — shipped r54, disabled r56, deleted r87.
