# FMEA — symptom → cause → where

Organised by **what you are staring at**, so it is reachable *before* the theory
rather than quoted after it. The codemaps are organised by place; this is the
index into them by symptom.

**Read the relevant section before forming a theory about any failure.**

Every `Where` cell names a real file and a real symbol. `make verify-docs` fails
when one stops resolving — a stale `Where` cell is a broken document, not an
out-of-date one.

---

## §A — a build, toolchain or project failure

| Symptom | Cause | Where |
|---|---|---|
| A file you added is not in the built target | `MagicCamera.xcodeproj` is generated from `project.yml` and committed; you did not regenerate | `project.yml` · `sources` |
| `xcodebuild` fails naming a destination that does not exist | **no simulator runtime is installed on this host** (2026-09-10) — the `iPhone 17` device was created against iOS 26.3, Xcode here is 26.2, so it reports `runtime profile not found`. CI is a different machine and names its own simulator | `Makefile` · `SIM` |
| `No available simulator runtimes for platform iphonesimulator. SimServiceContext supportedRuntimes=[]`, blamed on `Assets.xcassets` | same missing runtime: `actool` needs one even for a **device** destination, so `build-device` fails too. It is not the asset catalogue. Fix: `xcodebuild -downloadPlatform iOS`; until then `make compile-check` excludes the catalogue and compiles every other source | `Makefile` · `compile-check` |
| CI is red but the code compiles | the `docs` job — a document drifted from the tree; run `make verify-docs` and read the rule tag | `scripts/verify-docs.py` · `def main` |
| Stack overflow / "unable to type-check" naming `body` | `SpatialScanView`'s tools tree at the type-metadata limit — extract a nominal sub-`View` | `MagicCamera/SpatialScan/SpatialScanView.swift` · `body` |
| A run-script phase cannot read `.git` or write its output | `ENABLE_USER_SCRIPT_SANDBOXING: YES` — put it in the `Makefile` instead | `project.yml` · `ENABLE_USER_SCRIPT_SANDBOXING` |
| Debug build is "wrongly" optimised | deliberate: `-Onone` is 10–30× slower in the scan hot loops and trips the 90 s watchdog | `project.yml` · `SWIFT_OPTIMIZATION_LEVEL` |
| A "regression" of N new test failures | you counted XCTest's *assertion* tally — count with `grep "' failed ("` | `Makefile` · `test` |
| The commit you just made is missing files | the shell's cwd flapped between worktrees — always `git -C <abs>` | `CLAUDE.md` · §1 |
| A build shows a Point/Mesh scan-kind picker | that build is **stale**; mesh mode was removed by design | `MagicCamera/SpatialScan/ScanRecipe.swift` · `Kind` |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | **it is not missing.** It is an on-demand disk image under `~/Library/Developer/DVTDownloads/MetalToolchain/mounts/`; a CLI build that starts before it is attached gets this. Re-run — do **not** re-download it | `Makefile` · `build` |
| `swift-frontend` crash — in `DefineUsedVTables` building the **UIKit** PCM, or a segfault in `fine_grained_dependencies::AbstractSourceFileDepGraphFactory::construct()` ending a compile batch — or `The Xcode build system has crashed` | transient, and **not** simulator-specific: the dependency-graph segfault hit a `generic/platform=iOS` arm64 build on 2026-09-11 and the retry compiled clean. Retry once before believing any of these; keep a private `-derivedDataPath` so CLI builds never share Xcode's module cache | `Makefile` · `DEST` |

## §B — a scan came out wrong

| Symptom | Cause | Where |
|---|---|---|
| Bands / rings of points "like a radar sweep"; holes no resweeping fills | distance coarsening quantising positions into shells — must stay gated on real cap pressure | `MagicCamera/SpatialScan/ScanRecorder.swift` · `adaptiveSnap` |
| Floor is a slab, not a surface; walls stack at two offsets | the same wall stored on two lattices — same cause as above | `MagicCamera/SpatialScan/ScanConfig.swift` · `adaptiveVoxelPressureFraction` |
| Floor measurably off level; tilt grows over the sweep | ICP roll/pitch compounding, invisible to the translation guard | `MagicCamera/SpatialScan/FrameToModelICP.swift` · `leveled` |
| Registration reported healthy while the model drifted | drag measured at the world origin instead of at the data (lever arm) | `MagicCamera/SpatialScan/FrameToModelICP.swift` · `drag` |
| A whole object (a table) is in the cloud and absent from the mesh | a confidence bar taking the body, not the tail — height-profile both files and compare the band | `MagicCamera/SpatialScan/SpatialScanViewModel+Cleanup.swift` · `unreliableBar` |
| Half the cloud disappears between `raw` and `kept` | a hardcoded confidence bar rather than the grading's own mark | `MagicCamera/SpatialScan/DepthSampleConfidence.swift` · `grade` |
| "Make 3D model" returns regular flat slabs | the room's planar regulariser ran on a subject | `MagicCamera/SpatialScan/MeshPlanarRegularizer.swift` · `regularize` |
| A subject reconstructs as a pancake (99% of area in one plane) | isolation handed the reconstruction a fragment; the planar gate stops the consequence, not the cause | `MagicCamera/SpatialScan/SpatialScanViewModel+Lattice.swift` · `isFlat` |
| Tapping a subject ruins the running scan | the tap cleared the accumulation instead of retargeting | `MagicCamera/SpatialScan/ScanRecorder.swift` · `clearAccumulation` |
| Most of the texture is invented, not photographed | triangle budget and atlas page budget not reconciled — check `repaired N/M` against `pages ≤ P` | `MagicCamera/SpatialScan/PhotoTextureBaker.swift` · `affordableTriangleBudget` |
| Blurry or smeared texture | keyframe sharpness/selection, or the per-triangle atlas `texSize` cap | `MagicCamera/SpatialScan/KeyframeSharpness.swift` · `weights` |
| Bleed: a subject's mesh grows the room behind it | free-space carving strength, or a missing scene-mesh mask | `MagicCamera/SpatialScan/SurfaceMask.swift` · `maskToSurface` |
| Hole fill / component trim finds no neighbours | the mesh is duplicated-corner soup — **weld first** | `MagicCamera/SpatialScan/MeshData.swift` · `weld` |
| AR Quick Look refuses an exported USDZ | written with ModelIO instead of SceneKit | `MagicCamera/SpatialScan/MeshExporter.swift` · `Format` |
| A USDZ read back from the command line has an identical bbox on all axes | `SIMD3<Float>` has a 16-byte stride; flatten to `[Float]` | `docs/analysis/HANDOFF-r88.md` · `stride` |
| Object scan reports `surface cleanup — planes N > 0` | a subject was flattened; Object must report `0` | `docs/CODEMAPS/diagnostics.md` · `surface cleanup` |

## §C — memory, watchdog, thermals

| Symptom | Cause | Where |
|---|---|---|
| "Failed to terminate" watchdog kill on backgrounding | review-time reconstruction or bake survived into the background | `MagicCamera/SpatialScan/SpatialScanView.swift` · `handleEnterBackground` |
| Jetsam / OOM during a texture bake | the multi-view blend's slice size multiplied by keyframe count — never raise `slicePixels` | `MagicCamera/SpatialScan/GPUTextureBaker.swift` · `sliceSize` |
| 90 s CPU watchdog during reconstruction | lattice sized too fine for the area — the density rule is the lever | `MagicCamera/SpatialScan/SpatialScanViewModel+Lattice.swift` · `densityResolution` |
| Gigabytes of autosave writes on a long scan | the growth gate — writes must stay a small multiple of the final cloud | `MagicCamera/SpatialScan/SpatialScanViewModel.swift` · `autosaveGrowthThreshold` |
| `EXC_BAD_ACCESS` in `objc_autoreleasePoolPop` off-main | ModelIO over-release; wrap off-main ModelIO in `autoreleasepool` | `MagicCamera/SpatialScan/USDZMeshImporter.swift` · `autoreleasepool` |
| Crash inside a dispatch source event handler | Swift 6 MainActor/GCD closure trap — the handler must be `@Sendable` | `MagicCamera/Core/MemoryPressureMonitor.swift` · `level` |
| Critical memory pressure with no back-off | **there is no governor yet** — known gap, not a mystery | `docs/analysis/07-roadmap.md` · `Peak memory` |

## §D — you are about to write code

| Situation | Do this instead | Where |
|---|---|---|
| Adding an `if` to a view model | pull it out to a `static func` over its inputs and add a row | `docs/CODEMAPS/policy.md` · `policy-bearing` |
| Adding a knob with no argument | a `static var` in a policy file is a rule too, and needs its row | `MagicCamera/SpatialScan/SpatialScanViewModel+Lattice.swift` · `activeRoomLatticeFloorCell` |
| Adding a breadcrumb whose text starts with an interpolation | nothing can read its kind — put a literal word first, or allowlist the file with a reason | `scripts/verify-docs.py` · `CRUMB_DYNAMIC` |
| Naming a test in a live document | name the **class**, not the file it lives in — `make verify-docs` checks both the case and the count | `scripts/verify-docs.py` · `check_tests` |
| Starting a long review-time operation | funnel it through the operation runner so it completes exactly once | `MagicCamera/Core/OperationRunner.swift` · `runOperation` |
| Adding a tuning constant | put it in `ScanConfig` with the reason it has that value | `MagicCamera/SpatialScan/ScanConfig.swift` · `voxelSize` |
| Adding a new GPU kernel | ship the CPU fallback and a spot-check in the same commit | `MagicCamera/SpatialScan/GPUPointProcessor.swift` · `removeRadiusOutliers` |
| Building from a manual selection | trust the user's pick verbatim | `MagicCamera/SpatialScan/SpatialScanViewModel+Cleanup.swift` · `userIsolated` |
| Adding a filter that could delete a lot | make it refuse rather than ship a plausible result | `MagicCamera/SpatialScan/SurfaceMask.swift` · `maskToSurface` |
| Adding user-facing text | never build it by concatenation — the literal is the key | `Tests/MagicCameraTests/LocalizationTests.swift` · `testTheTranslationsCoverExactlyTheKeySet` |
| Shipping a behaviour change | add the breadcrumb that proves it in the same commit | `MagicCamera/Core/Diagnostics.swift` · `exportArchive` |

## §E — you are about to trust a document

| Document | Trust it for | Not for |
|---|---|---|
| `CLAUDE.md` | the rules | current numbers |
| `docs/CODEMAPS/` | where things are, and every tested rule | state, counts, timings |
| `docs/analysis/` handoffs | why a round did what it did | test names and counts — they are exempt from the citation check on purpose |
| `docs/analysis/VISION.md` | whether something should exist | what is built |
| `docs/analysis/07-roadmap.md` | what is open | anything after its verification date |
| the newest `docs/analysis/HANDOFF-rNN.md` | what the last round measured and left open | earlier rounds' numbers |
| older handoffs, `NEXT-CHAT.md`, `r71-device-round.md` | **why a constant has its value** | planning — they are history |
| `docs/ARCHITECTURE.md` | the two-mode shape | its inventory; it predates several removals |
| any number in prose | the day it was written | today |
| any commit message | intent | the diff — check it |
