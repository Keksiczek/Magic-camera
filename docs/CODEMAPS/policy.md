# policy — every decision rule, by name

**A rule inside a view model is a rule with no test.** The convention here is
that any decision worth arguing about is pulled out to a `static func` over its
inputs — or a `static var`, which is the same decision with no argument — in a
policy-bearing file, and tested against the device numbers that motivated it.

**If you are about to add an `if` to a view model or a service, the answer is
nearly always a new row in this table.**

`make verify-docs` fails when a policy-bearing file gains a rule this page does
not name. **Name it in backticks** — `symbol` or `File.symbol`; prose does not
count, because prose is what the rule exists to replace. The policy-bearing
files are listed at the bottom.

---

## Ingest — is this depth sample believable?

`SpatialScan/DepthSampleConfidence.swift` — each sample is *graded*, not passed
or failed. The grade multiplies its confidence, fusion weights by that, and the
reconstruction drops what never earned belief.

| Rule | Decides |
|---|---|
| `grade` | the combined score. **Rejection requires several signals to agree** — no single one can veto a sample |
| `isRejected` | the score is below the reject bar |
| `edgeFactor` | silhouette proximity — flat below the knee, then ramps |
| `incidenceFactor` | grazing incidence — 1.0 above the trusted angle |
| `rangeFactor` | distance — only bites beyond the trusted range |
| `radialFactor` | position in frame — mild, and only at the edge |
| `motionFactor` | camera motion — takes the worst of linear and angular |
| `relativeJump` | the depth cliff test, matching the GPU kernel's missing-neighbour handling |
| `cosIncidence` | surface slant from the depth neighbourhood |
| `cameraPoint` | the unprojection the factors are computed in |
| `ramp` | the shared soft-gate shape |
| `gpuGrading` | the GPU path carries **the same constants** as Swift, and a zero frame grade cannot reject a perfect sample |

Tests: `DepthSampleConfidenceTests` (25 cases).

## Capture — budget, motion, coaching

| Rule | File | Decides |
|---|---|---|
| `adaptiveSnap` | `ScanRecorder.swift` | distance-based lattice coarsening. **A budget guard, not a quality policy** — inert below `adaptiveVoxelPressureFraction` of the cap, because unconditional it stamped radar rings and unfillable holes |
| `supportCrops` | `ScanRecorder.swift` | whether the support-plane crop applies to this sample |
| `hint` | `CaptureGuidance.swift` | slow down / move back / more light — motion outranks darkness, and a dim but richly textured frame is left alone |
| `imageSpeed` | `CaptureGuidance.swift` | apparent motion from linear + angular speed at the subject's distance |
| `capture` | `CaptureQuality.swift` | expected points and memory, shown **before** the scan starts |
| `reconstruction` | `CaptureQuality.swift` | expected triangles, memory and speed band, shown before a reconstruction |
| `objectConfig` | `CaptureQuality.swift` | Object / Object+ fine voxel and range clamp |
| `roomConfig` | `CaptureQuality.swift` | the room profile |
| `measure`, `weights` | `KeyframeSharpness.swift` | per-keyframe sharpness, and bounded monotonic weights over it |
| `sparseFlags` | `ScanDensityMap.swift` | which cells are too sparse to trust |
| `level` | `Core/MemoryPressureMonitor.swift` | the pressure level — critical wins when both bits are set |

## Finish and reconstruct — lattice, crop, refusal

| Rule | File | Decides |
|---|---|---|
| `densityResolution` | `+Lattice.swift` | lattice cell from bounding-box **area**, with a device-measured room noise floor that Object never inherits |
| `activeRoomLatticeFloorCell` | `+Lattice.swift` | the floor a room reconstruction actually runs at — read from UserDefaults inside detached work, so the fine floor is a user choice, not a build constant |
| `latticeBound` | `+Lattice.swift` | the ceiling on lattice resolution for this cloud |
| `reconstructionTriangleTarget` | `+Lattice.swift` | triangle target from the point cap |
| `cappedForBake` | `+Lattice.swift` | trim a mesh to what the atlas can actually texture |
| `supportSurvivedTheCrop` | `+Lattice.swift` | whether the crop left the subject standing on anything |
| `isFlat` | `+Lattice.swift` | the pancake test — a subject that reconstructs flat is a failure, not a result |
| `recoverViewDirections` | `+Lattice.swift` | rebuild per-point view rays for a subset that lost them |
| `unreliableBar` | `+Cleanup.swift` | the confidence bar for thinning. **It is the grading's own doubtful mark, never a higher one** — a badly graded scan is thinned, not gutted |
| `droppingLassoBackground` | `+Cleanup.swift` | depth-aware lasso: keep what the user drew round, drop what is behind it |
| `tolerance`, `maskToSurface`, `floorLevel`, `croppingAbove`, `cleaned` | `SurfaceMask.swift` | crop a cloud to a captured surface. **`maskToSurface` returns nil rather than gutting the cloud** |
| `drag`, `tilt`, `leveled`, `planeNormal`, `solve`, `solve6`, `rotationMatrix` | `FrameToModelICP.swift` | per-frame registration. `drag` is measured **at the data**, not the world origin; `leveled` removes roll/pitch, keeps yaw, and stops tilt compounding; `planeNormal` falls back when the patch is untrustworthy |
| `standard`, `withSubjectSteps` | `ScanRecipe.swift` | the ordered post-process plan. Model always isolates, Surface never does, the canonical order covers every step exactly once, and every step can be switched by hand |
| `measure`, `kind`, `ceilingHeight`, `occupiedColumns` | `ScanMetrics.swift` | what the scan *is* — room / area / surface / object — and its footprint, ignoring the air above a table |

## Texture bake — what the budget can afford

| Rule | File | Decides |
|---|---|---|
| `affordablePageBudget` | `PhotoTextureBaker.swift` | atlas pages this triangle count and keyframe set can pay for |
| `affordableTriangleBudget` | `PhotoTextureBaker.swift` | its inverse — **the two must stay reconciled**, or the texture is synthesised rather than photographed |
| `selectingBakeKeyframes` | `PhotoTextureBaker.swift` | sharpest, pose-diverse, capped |
| `makeViews` | `PhotoTextureBaker.swift` | keyframes → bakeable views |
| `smoothViewAssignment` | `PhotoTextureBaker.swift` | Pass-1.5 view smoothing, so charts do not tile from alternating photos |
| `exposureGain` | `PhotoTextureBaker.swift` | per-view exposure harmonisation |
| `trimmingGhostSheets` | `PhotoTextureBaker.swift` | drop sheets no keyframe ever saw |
| `repairUnwrittenTexels` | `PhotoTextureBaker.swift` | the repair count that the `repaired N/M` breadcrumb reports |
| `batchSize`, `sliceSize`, `batchedSliceSize` | `GPUTextureBaker.swift` | keep the multi-view blend inside memory. **Do not raise `slicePixels`** — it multiplies by keyframe count |

## Autosave, session and reporting

| Rule | File | Decides |
|---|---|---|
| `autosaveInterval` | `SpatialScanViewModel.swift` | cadence by point count — monotonic, small scans still checkpoint often |
| `autosaveGrowthThreshold` | `SpatialScanViewModel.swift` | the growth gate. Total writes stay a small multiple of the final cloud |
| `confidenceHistogram`, `gradingStats` | `SpatialScanViewModel.swift` | what the `scan quality` breadcrumb reports; tombstones are ignored |
| `icpFreezeNote` | `SpatialScanViewModel.swift` | what to tell the user when registration is frozen |
| `mostRecentSavedURL` | `SpatialScanViewModel.swift` | which saved scan a resumed session belongs to |

## Regularise — when a wall may be flattened

`SpatialScan/MeshPlanarRegularizer.swift` — the step that made a subject into
slabs in r54 and again in r87. It runs on *scenes*; on a subject it is off, and
the FMEA row for "Make 3D model returns regular flat slabs" points here.

| Rule | Decides |
|---|---|
| `regularize` | how many dominant planes may be flattened at all — 0 returns the input unchanged |
| `manhattanLocked` | which planes are close enough to the room's frame (~20°) to be locked onto an exact axis, offset refit to their own inliers so the wall stays where the data is |
| `manhattanFrame` | the room's orthogonal frame: gravity, plus the yaw consensus of the wall normals folded by 4θ averaging |
| `mergedSeeds` | near-coplanar seeds collapse into one claim — one wall, one plane — capped, largest wins |
| `adaptiveTolerance` | the distance tolerance, scaled to the scan's diagonal: ~2.5 cm at room scale, up to ~9 cm on a building |

Tests: `MeshPlanarRegularizerTests` (8 cases), including the subject that must
keep its depth and the same subject flattened when it is treated as a scene.

## Isolate — what may be removed from a cloud

`SpatialScan/PointCloudSegmenter.swift` — every rule here **deletes the owner's
points**. Apple's trust order applies: what the user or a photo mask picked is
kept, and the automatic step gives way.

| Rule | Decides |
|---|---|
| `detectDominantPlane` | whether a plane holds enough of the cloud to be the support at all — nil when it does not |
| `removingPlane` | the cloud minus that plane's inliers |
| `removingPlaneAndBelow` | also everything on the far side, so an object is lifted off its support rather than bridged to it |
| `clusters` | what counts as connected — 26-adjacency on a lattice of `cellMultiplier` × mean spacing |
| `removeStrayClusters` | which detached specks are flying pixels rather than a second object |
| `isolateMaskedSubject` | the mask has already decided: strip the support, shed floaters, **keep the rest** |
| `isolateMainSubject` | the historical single-subject entry point, unchanged |
| `isolateSubjects` | one subject per anchor, each re-united from its fragments; with no anchors, the best single cluster |

Tests: `SegmenterAndBakerTests` — the floor plane, the specks that go, the
multi-object scene that stays.

## Primitive snap — when a turned surface may be idealised

`SpatialScan/MeshPrimitiveSnap.swift` — the family the louver regulariser came
from. It must refuse far more often than it fires.

| Rule | Decides |
|---|---|
| `snap` | how many primitives may be idealised; an unqualifying mesh is returned untouched |
| `fitRevolution` | whether the mesh really holds a turned surface about this axis |
| `seedSphere` | the sphere a point pair and their normals imply |
| `candidateAxes` | which axes are worth testing — world-up, plus the pool's principal axes for a lying object |

Tests: `MeshPrimitiveSnapTests` (10 cases) — and the rejections matter more
than the fits: a box, a flat wall, a mug handle and a decoration all survive.

## Naming and auto-fix — what the on-device model may decide

`SpatialScan/ScanIntelligence.swift` — the model never touches geometry. It
names things and proposes a plan; both fall back to deterministic rules.

| Rule | Decides |
|---|---|
| `facts` | the fact sheet everything downstream sees — the model gets no other view of the scan |
| `describeScene` | model description when the model is there, the fact summary when it is not |
| `suggestName` | a library name, so the shelf is not a wall of `Scan 2026-07-30 12:04` |
| `sanitizedName` | what is safe to become a filename; nil sends the caller to the fallback |
| `planAutoFix` | the ordered clean-up plan, from a fixed tool vocabulary — invalid names dropped, empty falls back |
| `heuristicPlan` | that fallback: the same steps a careful user would click |

Tests: `ScanNamingTests` (9 cases) — the naming rules and the filename guards.

---

## Policy-bearing files

`make verify-docs` scans exactly these for `static func` and `static var`, and
requires each name above. The list is checked in both directions: a file named
here that the script does not scan fails too.

```
MagicCamera/SpatialScan/DepthSampleConfidence.swift
MagicCamera/SpatialScan/CaptureGuidance.swift
MagicCamera/SpatialScan/CaptureQuality.swift
MagicCamera/SpatialScan/FrameToModelICP.swift
MagicCamera/SpatialScan/KeyframeSharpness.swift
MagicCamera/SpatialScan/ScanDensityMap.swift
MagicCamera/SpatialScan/ScanMetrics.swift
MagicCamera/SpatialScan/ScanRecipe.swift
MagicCamera/SpatialScan/ScanRecorder.swift
MagicCamera/SpatialScan/SurfaceMask.swift
MagicCamera/SpatialScan/PhotoTextureBaker.swift
MagicCamera/SpatialScan/GPUTextureBaker.swift
MagicCamera/SpatialScan/SpatialScanViewModel.swift
MagicCamera/SpatialScan/SpatialScanViewModel+Lattice.swift
MagicCamera/SpatialScan/SpatialScanViewModel+Cleanup.swift
MagicCamera/SpatialScan/MeshPlanarRegularizer.swift
MagicCamera/SpatialScan/PointCloudSegmenter.swift
MagicCamera/SpatialScan/MeshPrimitiveSnap.swift
MagicCamera/SpatialScan/ScanIntelligence.swift
MagicCamera/Core/MemoryPressureMonitor.swift
```

Pure mechanics inside those files (the bake entry points, decoders, fallback
painters) are exempted **by name with a reason** in
`scripts/verify-docs.py` → `POLICY_EXEMPT`. Adding to that list means writing
down why the thing is not a decision, which is harder than writing the row.
