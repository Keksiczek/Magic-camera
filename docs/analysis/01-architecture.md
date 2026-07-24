# 01 · Architecture, Concurrency & Infrastructure

_Scope: app/router, view models, engines, stores, GPU, cloud, core infra.
Worktree HEAD `e20dbfb`, Swift 6.0 strict concurrency._

**Verdict:** the concurrency foundation, diagnostics, codec robustness, and
GPU/CPU-fallback discipline are genuinely strong — above typical indie-app quality.
The codebase is ~70% of the way to a best-in-class architecture. The remaining gaps
are concentrated: the god-object view model, a **missing memory-pressure governor**,
and two divergent orchestration patterns.

## Architecture map

```
APP / ROUTER
  MagicCameraApp (entry: Diagnostics.start, sweepStaleExports)
  RootView (NavigationStack(path:), deep-link handler, CloudStore.start)
  AppRouter  @MainActor @Observable  (path, pendingGalleryPick, pendingStudioImport)
        │
VIEW MODELS  @MainActor @Observable                 SwiftUI Views
  SpatialScanViewModel (+Editing/+Export/+Intel)     ScanARView (UIViewRepresentable
    ← the god object                                   + Coordinator: ARSessionDelegate)
  ModelStudioViewModel, LiveDepthCameraViewModel, RoomPlanScan
        │
  ┌─────────────┬──────────────┬──────────────┬───────────────┐
CAPTURE        ENGINES         STORES          GPU             CLOUD / WIDGET
 ScanRecorder  (pure value /   FileStore →     MetalContext    CloudStore
 (@unchecked    nonisolated)    ScanStore       ScanComputeUn-  (@MainActor Observable)
  Sendable,    Reconstruction   MeshStore        projector      FileStore ← base dir
  serial Q)    Pipeline,        StageStore      GPUPointProc    Widget: App-Group
 MeshAnchor    Smooth/BallP     ScanKeyframe    GPUTextureBaker  snapshot
  Collector    Mesh* tools      Store           +3 .metal +
 ScanCompute   PhotoTexture     Scan/Studio     CPU fallbacks
  Unprojector  Baker, ICP…      AutoSave         everywhere
  └─────────────┴──────────────┴──────────────┴───────────────┘
        │
CORE INFRA:  Diagnostics (singleton) · AppSettings + isolation-free enum readers
             · DeviceCapabilities · Math · Concurrency (UncheckedSendableBox)
```

Dependencies are clean and largely acyclic: Views → ViewModels → {Recorder, Engines,
Stores} → Core. The store layer's only coupling to iCloud is one call —
`FileStore.directory()` asks `CloudStore.baseDirectory` — so the stores inherit sync
without knowing about it. The widget depends on **nothing** in app storage; it reads
only the App-Group snapshot. Global-state seams: `AppRouter`, `AppSettings`,
`CloudStore`, `Diagnostics`.

## Concurrency model

Swift 6.0 strict concurrency, disciplined and correct in the hot paths.

- **The `runOperation` backbone** (`SpatialScanViewModel.swift:505`) is the standout:
  every review-time op gets an exclusive-slot gate (`activeOperation`), a
  **stale-result guard** (`workGeneration` captured at start, re-checked before
  apply), cooperative cancellation (`heavyWorkCancel` → `task.cancel()`), a
  background-task assertion (survives screen-lock instead of a suspend-watchdog
  SIGKILL), and signpost + breadcrumb telemetry. Sound `@MainActor`/`Sendable`
  signatures throughout.
- **Off-main confinement is consistent:** `ScanRecorder` confines mutable capture
  state to a serial queue with `NSLock` frame **backpressure** (max 2 in flight, to
  dodge ARKit's ARFrame-retention throttle); the ARSession delegate runs on a
  dedicated serial queue (main thread never blocked by recorder reads); callbacks are
  `@MainActor @Sendable`.
- **Every unsafe marker is justified:** 9 `@unchecked Sendable` (lock/queue-guarded
  or one-shot boxes), 4 `nonisolated(unsafe)` (all protected), and the sanctioned
  `UncheckedSendableBox` value-snapshot hop. No retain cycles (`[weak self]` universal).

**Concurrency risks:**
- **Two divergent orchestration patterns (biggest inconsistency).**
  `ModelStudioViewModel` does *not* use `runOperation` — plain `isProcessing` +
  `await Task.detached{}.value`, so **no stale-guard and no cancellation**: a
  completing detached op can apply a stale result if the stage changed under it, and
  can't be aborted on background.
- **Cooperative cancel is partial** — only ops that poll `Task.isCancelled` stop
  (reconstruction does; `MeshOptimizer.smooth`, `MeshDecimator.decimate`,
  `ICPRegistration.merge` don't → a "cancelled" op burns CPU to completion).
- **Busy-wait** in auto-fix (`+Intelligence.swift:98`): `while activeOperation != nil
  { sleep(120ms) }` — should await a continuation.
- **Latent ARKit cross-thread read:** `MeshAnchorCollector` stores live
  non-Sendable `ARMeshAnchor` refs and reads geometry off its own queue while ARKit
  may mutate them (common, low risk, not strictly safe).

## State & data model

- **Domain types are value types** (`PointCloud` SoA, `MeshData`, `TexturedMesh`,
  `StudioObject`); big non-diffable state is `@ObservationIgnored`.
- **Persistence is hand-rolled compact binary** with versioned magic headers, all
  backward-compatible (ScanStore v2 view rays, MeshStore v2 texture, StageStore v2
  per-object texture, ScanKeyframeStore v2 sharpness). Decoders are bounds-checked and
  degrade gracefully — a truncated file returns partial/nil, never crashes. Encoders
  bulk-append one contiguous buffer to dodge the per-element `swift_dynamicCast` stall.
  - _Minor:_ `MeshStore.decodeFull` reads the main body with **aligned** loads
    (relying on `Data`'s 4-aligned backing) while the rest use `loadUnaligned` — a
    latent assumption; unify to `loadUnaligned`.
- **Undo/redo is doubly bounded** — depth (8) *and* a 250 MB budget via
  `estimatedBytes` — right for multi-million-point clouds.
- **iCloud layering is well-isolated** — `CloudContainer` caches the ubiquity URL
  behind `NSLock`; blocking lookup runs once off-main at launch; `baseDirectory` is
  isolation-free; migration idempotent + best-effort; `NSMetadataQuery` watches
  remote changes; autosave stays local.
- **Crash recovery** is symmetric (scan + Studio), serial-queue + atomic, with
  autosave cadence that **scales with cloud size** to curb the `.diskWrites` watchdog
  (a documented fix for a 4.4 GB write session).

## Strengths

1. **Field diagnosability is best-in-class** — `Diagnostics` (breadcrumbs + MetricKit
   crash/CPU/hang/diskwrite + `⚡︎GPU/○CPU` telemetry + signposts): every op,
   cancellation and watchdog kill is reconstructable from an exported `.txt`.
2. **The `runOperation` operation-runner** — exclusive slot + stale-guard + cancel +
   bg-assertion + telemetry in one place.
3. **GPU-with-CPU-fallback everywhere**, plus a **CPU correctness spot-check** that
   validates the GPU signed-field against a CPU reference before trusting it — a
   kernel bug can never ship a wrong surface.
4. **Watchdog defense in depth** — triangle budgets, <4M reconstruction band cap,
   chunked capture, frame backpressure, size-scaled autosave.
5. **Excellent hygiene** — 0 `print`/`TODO`/`try!`/`fatalError`/`as!`; the 6 force
   unwraps are provably safe; ~220 test functions across 33 files cover the algorithmic
   core + codecs.
6. **Kill switches** in Settings for every risky feature (GPU bake, adaptive
   reconstruction, frame alignment, shape snapping), read isolation-free.

## Tech debt & risks

- **No runtime memory-pressure handling (HIGH).** No
  `DispatchSource.makeMemoryPressureSource`, no `didReceiveMemoryWarning`. OOM defense
  is entirely **open-loop** (static `physicalMemory` tiering + hard caps). An 8192²
  atlas + photo-slice array + multi-million-point cloud + 250 MB undo stack + keyframes
  can coincide → realistic **jetsam risk** under external pressure. Single biggest
  crash-risk gap.
- **`SpatialScanViewModel` is a god object** — one type across 4 files owning capture
  lifecycle, autosave, ~40 observable properties, 20+ review ops, export, and
  intelligence; `makeQuickModel` alone is ~430 lines.
- **Oversized files** (>800 LOC): `ScanRecorder` 1945, `+Editing` 1731, VM 1446,
  `ScanARView` 1051, `SpatialScanView` 964, `SpatialScanReviewTools` 933,
  `PhotoTextureBaker` 905.
- **Magic numbers pervade** the pipeline — superbly documented, but tuning lives in
  comments + the memory file rather than a typed config.
- **Divergent orchestration** — Studio lacks the scan VM's stale-guard/cancellation.
- **Silent-by-design failures** — many `try?`/fallbacks swallow errors with only a
  breadcrumb (a full-disk autosave failure surfaces only as a breadcrumb).
- **No shared `MetalContext`** — each GPU op rebuilds device+queue+library (minor,
  one-shot ops, but wasteful).
- **Singletons reduce testability** — no DI seam for VM-level tests (there are none).

## Recommendations (prioritized)

**P0 — before submission**
1. **Add a memory-pressure governor.** `DispatchSource.makeMemoryPressureSource([.warning,.critical])`
   + `didReceiveMemoryWarning`: on warning shed undo/redo + overlay caches; on critical
   abort/step-down in-flight bakes (atlas 8192→6144, slice size). Gate the atlas +
   photo-array allocation on `os_proc_available_memory()` in addition to the static
   tier. Closes the biggest crash-risk gap.
2. **Device-verify this branch** — the keyframe-batching / slice-3072² / maxKeyframes-96
   work here is explicitly **not device-verified** (per memory). Run a real large-room
   scan; confirm bake time, `unseen%`, peak capture memory before shipping.

**P1**
3. **Unify the operation runner** — extract `runOperation` + `workGeneration` + cancel
   + bg-assertion into a shared testable `OperationRunner`; adopt in
   `ModelStudioViewModel` so Studio inherits stale-guard + cancellation.
4. **Decompose `SpatialScanViewModel`** by responsibility — `ScanCaptureController`,
   `ReviewEditingController`, `ExportController`; move the `nonisolated static`
   geometry helpers into the engine layer where they're unit-testable.
5. **Centralize tuning** into a typed `ScanTuning`/`ReconstructionTuning` namespace so
   the pervasive literals become named, discoverable constants — safer device A/B.

**P2**
6. Replace the auto-fix busy-wait with a runner-resolved continuation.
7. Make `MeshStore.decodeFull` fully `loadUnaligned`.
8. Introduce protocols/DI over the singletons; add VM-level tests around the
   `runOperation` stale-guard/cancel semantics (the one untested layer).
9. Share a single `MetalContext` across GPU drivers.
10. Snapshot `ARMeshAnchor` geometry to a Sendable value at update time.

**Best-in-class target:** a thin `@MainActor` Observable presentation layer over a
Sendable "scan domain" engine (behind protocols), one shared cancellable operation
runner, a typed tuning config, the repository-shaped store layer, and a reactive
memory-pressure governor. The foundation is already strong; the gaps are the
god-object VM, the memory governor, and the two orchestration patterns.
