# Architecture

The guiding rule (from the spec): **separate data acquisition from rendering**,
keep modules small and replaceable, and never fake depth data.

## Mode 1 — Live Depth Camera

```
ARSession ──(ARFrame)──► DepthEngine ──currentFrame──► MetalDepthView.Coordinator
                                                          │
                          EffectSettings (ViewModel) ─────┤
                                                          ▼
                                                   EffectRenderer  ──► MTKView drawable (preview)
                                                          ├────────► CGImage  (photo)
                                                          └────────► CVPixelBuffer ──► VideoRecorder (.mp4)

tap ──► DepthSampler ──(depth + pose)──► world point ──► measure distance
```

- **`DepthEngine`** owns the `ARSession` (frame semantics `.sceneDepth` +
  `.smoothedSceneDepth` when available), exposes the latest `ARFrame`
  thread-safely, reports status. No rendering.
- **`DepthEffect` / `EffectSettings`** — the effect model the UI binds to;
  converts parameters + a per-frame `FrameUniformContext` (view→image transform,
  depth texel, depth intrinsics, depth size, light direction) into
  `EffectUniforms`. `DepthEffectKind` raw values are kept in sync with the C
  `EffectType` enum (unit-tested).
- **`EffectRenderer`** — one Metal pipeline, one fullscreen pass, three entry
  points sharing an `encode` path: live `draw`, `snapshot` (→ CGImage),
  `render(into:)` (→ CVPixelBuffer for video). YCbCr→RGB, depth sampling,
  normals reconstruction and the selected effect happen in `Effects.metal`.
- **`DepthSampler`** — converts a screen tap into a world-space point (inverse
  display transform → depth pixel → unproject via `DepthMath`), powering the
  tap-to-measure tool.
- **`LiveDepthCameraViewModel`** (`@Observable`, `@MainActor`) — active effect,
  parameters, capture/record orchestration, measure state, transient toasts.

The view→image sampling transform is the inverse of
`ARFrame.displayTransform(for:viewportSize:)`, so depth and colour are sampled
consistently with aspect-fill (UI locked to portrait).

## Mode 2 — Spatial Scan

```
                         ┌─ point mode ─► ScanRecorder.process ─► PointCloud ─┐
ARSCNView.session ──────►┤  (bg queue)     (unproject + colour + filter        │
 (sceneDepth, optional   │                  + voxel downsample + cap)          │
  sceneReconstruction)   └─ mesh mode ──► MeshAnchorCollector ─► MeshData ─────┤
                                            (ARMeshAnchors)                    │
                                                                              ▼
   live overlay (throttled points / mesh wireframe)            Review viewers (SCNView)
                                                               ├ MetalPointCloudView (Metal + EDL)
                                                               └ MeshViewer
                                                               shared OrbitCamera (presets + orbit)
                                                                              │
                              PointCloudExporter → PLY / OBJ ◄────────────────┤
                              MeshExporter (ModelIO) → USDZ / OBJ / STL ◄──────┤
                              ScanStore (.mcscan) ◄── save / load ── Gallery ──┘
```

- **`ScanRecorder`** turns each accepted depth pixel into a world point via
  `DepthMath` (scaled intrinsics → camera-local → world using the camera pose),
  samples colour from the YCbCr planes, filters by LiDAR confidence, and bounds
  memory with frame/pixel striding, a `VoxelGrid`, a `maxDepth` cut and a hard
  point cap. Reconfigurable via `ScanQuality` presets. Thread-safe; runs on the
  AR delegate's background queue.
- **`MeshData` / `MeshAnchorCollector`** — collect `ARMeshAnchor`s during a mesh
  scan and merge them (world-space vertices, normals, indices) for display/export.
- **`PointCloud` / `VoxelGrid`** — plain value types, ARKit-free, unit-tested.
- **`PointCloudSceneBuilder` / `MeshSceneBuilder`** — build `SCNGeometry` (points
  with colour modes / triangle mesh; plus a live wireframe straight from
  `ARMeshGeometry`).
- **`PointCloudViewer` / `MeshViewer`** — `SCNView`s with free camera control,
  auto-orbit and framing presets via the shared **`OrbitCamera`** helper.
- **`PointCloudExporter`** — PLY (binary LE / ASCII) and OBJ. **`MeshExporter`** —
  USDZ / OBJ / STL via ModelIO (`MDLAsset` from `SCNGeometry`).
- **`ScanStore`** — compact binary persistence of point clouds under
  `Documents/Scans/*.mcscan`; the gallery lists, loads and deletes them.

## Concurrency notes

- Swift 6 language mode (strict concurrency). Pragmatic patterns for ARKit delegate
  patterns. View models are `@MainActor @Observable`.
- Acquisition objects (`DepthEngine`, `ScanRecorder`, `MeshAnchorCollector`, AR
  coordinators) are plain classes that never touch main-actor state from
  background queues; shared state is guarded with `NSLock`.

## Extending

- **New live effect:** add a case to `EffectType` (ShaderTypes.h) + a branch in
  `Effects.metal`, a `DepthEffectKind` case + parameter flags, and any new fields
  in `EffectUniforms`/`EffectSettings`.
- **New export format:** add a `PointCloudExporter.Format` / `MeshExporter.Format`
  case + serializer.
- **Persistence:** `ScanStore` is the single read/write point; mesh persistence
  could mirror the point-cloud `.mcscan` path.

## Tests

Hardware-independent logic is unit-tested: `DepthMath` unprojection,
`VoxelGrid` dedup, `PointCloud` ops, `PointCloudExporter` (PLY/OBJ),
`ScanStore` round-trip, `ScanQuality` presets, `MeshData` bounds and the
`DepthEffectKind`↔`EffectType` contract.
