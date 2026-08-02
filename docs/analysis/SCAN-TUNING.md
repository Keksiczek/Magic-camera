# Scan tuning map

_Written 2026-08-02 (r77). The prerequisite for Tier 3.3 — and possibly its
replacement._

Every round since r43 has begun the same way: something in a scan looks wrong, and
the first twenty minutes go to finding which constant governs it. There are about
seventy of them across a dozen files, most with a hard-won reason attached, and no
index. This is the index.

**It deliberately does not move any code.** A constant belongs next to the maths
that reads it — a `ScanTuning` blob would put `carveStrength` five files away from
the ray march that uses it, and the comments explaining *why* each value is what it
is are worth more than the co-location. What was missing is a way to find them.
Read this, then go to the file.

Every value below is the shipping default at `ddb5386`. **When you change one,
change it here too** — a stale map is worse than none.

---

## 1. Capture — what enters the cloud

`ScanConfig` (`SpatialScan/ScanRecorder.swift:13`) is the per-scan knob set;
`CaptureQuality` (`SpatialScan/CaptureQuality.swift`) maps the user-facing quality
tiers onto it. Change the tier, not the field, unless the field is genuinely global.

| knob | default | what it decides |
|---|---|---|
| `frameStride` | 3 | ARFrames sampled out of 60 fps |
| `pixelStride` | 2 | depth-map subsampling |
| `voxelSize` | 0.012 | capture lattice; the cloud's own resolution |
| `maxPoints` | 600 000 | hard cloud cap |
| `maxDepth` | 5.0 m | range gate |
| `adaptiveVoxelNearDistance` / `BandWidth` / `MaxMultiplier` | 1.5 / 1.0 / 4 | distance-coarsening. **This is why a room's mean nn-spacing is misleading** — see §2 |
| `fusionMaxWeight` | 48 | TSDF saturation |
| `carveStrength` / `carveMaxSteps` | 1.4 / 24 | free-space ray-march that removes bleed |
| `icpEnabled` / `icpPriorStrength` | true / 0.15 | frame-to-model registration. Killable from Settings ▸ Frame alignment |
| `driftCorrectMeters` / `Radians` | 0.02 / 0.035 | ICP runaway guard, measured **at the data**, not the world origin (r60) |

### Per-sample confidence grading

`SpatialScan/DepthSampleConfidence.swift`. Five multiplicative factors; the product
under `minGrade` is the only thing that can reject a sample — **no single signal may
reject one on its own**, because several independent signals agreeing is bleed's
signature and any one of them alone is just a hard gate by another name.

| knob | default |
|---|---|
| `edgeKnee` / `edgeFloor` | 0.35 / 0.28 |
| `grazingCos` / `trustedCos` / `incidenceFloor` | 0.15 / 0.50 / 0.15 |
| `trustedRange` / `rangeFloor` | 1.5 m / 0.75 |
| `trustedRadius` / `radialFloor` | 0.65 / 0.85 |
| `steadyAngularSpeed` / `steadyLinearSpeed` | 0.35 / 0.20 |
| `blurredAngularSpeed` / `blurredLinearSpeed` | 1.20 / 0.60 |
| `motionFloor` | 0.50 |
| `minGrade` | 0.10 |
| `lowConfidenceMark` | 0.25 |

Kill switch: Settings ▸ Sample confidence. These reach Metal through a
`SampleGrading` uniform so CPU and GPU cannot drift apart.

---

## 2. Reconstruction — cloud into surface

`SpatialScan/SpatialScanViewModel+Editing.swift`.

| knob | default | what it decides |
|---|---|---|
| `roomLatticeFloorCell` | 0.028 | **the binding limit on room geometry today.** Depth noise scales with RANGE, not room size, so it applies to every room regardless of extent (r64 learned this the hard way — a size gate let small rooms reach ~1 cm and produced black holes) |
| `fineRoomLatticeFloorCell` | 0.020 | what Settings ▸ Finer room detail swaps in. The A/B, not a new default |
| `supportSlabFraction` / `supportSlabDensityRatio` | 0.40 / 2.5 | support-surface detection for object crops |

Two rules that keep being rediscovered:

- **Objects pass `noiseFloorCell: nil`.** They are scanned at ≤1.5 m where depth
  noise is mm-scale, so their own point spacing binds them.
- **A room's cloud is distance-coarsened**, so its MEAN nn-spacing is dragged up by
  the sparse far tail. Surfaces use `spacingPercentile(0.35)`; objects use the mean.
  Using the mean for a room throttled whole surfaces to far-wall coarseness — two
  same-size device rooms meshed 68 k vs 295 k triangles on scan distance alone.

The `lattice` breadcrumb prints `res · cell mm · bound by <term> · floor mm`, where
the term is one of `points` / `budget` / `band` / `noise-floor` / `spacing` /
`minimum`. **Read it before touching anything here** — the four candidate limits
need four different fixes.

---

## 3. Mesh post-processing

| file | knob | default | notes |
|---|---|---|---|
| `MeshPrimitiveSnap` | `minRadius` / `maxRadius` | 0.01 / 2.0 | `maxRadius` is why a flat face could pass as a sphere — a 2 m sphere bows 2.5 mm across 20 cm |
| | `sphereNormalAgreement` | 0.94 | ~20°. Added r74; without it a box lost 18 mm of flatness |
| | `maxSphereNormalResultant` | 0.97 | patch must actually curve |
| | `azimuthGate` / `minRadialNormal` | 0.40 / 0.30 | revolution path; **do not reuse for spheres**, they mean "not a cap", not "on the surface" |
| | `minAzimuthCoverage` | 0.6 | 16 sectors; a box's four face strips give 0.25 and are rejected |
| | `reliefSmoothingIterations` | 5 | keeps decoration while removing crinkle. Why the ball test tolerates mm-scale residual by design |
| | `maxShift` | 0.03 | a bad inlier can nudge, never teleport |
| `MeshCloudSnap` | `maxShift` | 0.03 | same guarantee |
| `MeshLouverSnap` | `minPeriod` / `maxPeriod` / `minSlats` / `minStrength` / `maxTroughRatio` | 0.01 / 0.30 / 5 / 0.40 / 0.40 | **disabled in the pipeline since r56** — false-fired on the marching-cubes lattice, read a plain room as a 120-slat blind and moved 95 % of its vertices. Re-enabling needs triangle-AREA density |
| `MeshHoleFiller` | `earClipMaxEdges` | 600 | |
| `FrameToModelICP` | `minCorrespondences` | 150 | lowered from 300 in r51; objects were starving at `0/577` |
| `ScanRecorder` | `icpCellSize` / `coverageCellSize` | 0.024 / 0.09 | |

---

## 4. Texture bake and atlas

| file | knob | default | notes |
|---|---|---|---|
| `ChartAtlas` | `gateCandidates` | `[0.75, 0.5, 0.25, 0.1]` | growth gate is SEARCHED, tightest first so a tie keeps the least distortion. Read the `uv gate search` trace before touching |
| | `packEfficiency` | 0.65 | shelf packing waste; also the constant in the density ceiling `texSize·√(0.65·pages/area)` |
| | `chartPadPx` | 4 | per-chart, on all four sides — the cost of shatter. `pad %` on the atlas summary says what it adds up to |
| `AreaProportionalAtlas` | `packEfficiency` | 0.6 | separate layout, unwired |
| `TextureAtlas` | `baselinePxPerCell` / `maxPxPerCell` | 16 / 40 | per-triangle fallback layout |
| | `atlasJPEGQuality` | 0.92 | Studio palettes stay PNG — flat colour rings |
| `PhotoTextureBaker` | `maxBakeViews` | 96 | |
| | `bakePageBytes` | 900 000 000 | page budget against live `os_proc_available_memory()`. **Not a pure function of its arguments** — any test asserting a page count is flaky by design |
| | `surfaceAtlasCap` / `surfacePageBudget` | computed | device-class dependent |

Two facts that keep costing rounds:

- **The single-sheet density ceiling is pure area accounting.** A 142 m² room in one
  8192² sheet is bounded at ~1.8 mm/texel *with a perfect unwrap*. N pages buy √N.
- **A single chart cannot straddle two pages.** The shelf packer spills whole
  charts, so a continuous surface pages exactly once however large it is.

---

## 5. Keyframes and photogrammetry

| file | knob | default |
|---|---|---|
| `KeyframePhotogrammetry` | `minimumKeyframes` / `maximumKeyframes` | 20 / 160 |
| `KeyframeSharpness` | `gridWidth` / `gridHeight` | 160 / 120 |
| `KeyframeSubjectFilter` | `maxViews` / `minKeptPoints` / `maxKeptFraction` | 3 / 2000 / 0.95 |

---

## 6. Cost models

`CaptureQuality.captureBytesPerPoint` = 80, `reconstructBytesPerTriangle` = 30.
`ExportPresets` holds the per-format size estimates (bytes per vertex, per
triangle, per ASCII point) used for the export-size labels.

---

## 7. Settings switches, and what each is for

All read off-main through the enums in `Core/AppSettings.swift`, because the paths
that consume them run detached.

| switch | default | why it exists |
|---|---|---|
| GPU texture bake | on | rule out a device-specific GPU issue without a rebuild |
| Frame alignment (ICP) | on | rule out a registration regression in the field |
| Shape snapping | on | A/B the snap; off just leaves the raw reconstruction |
| Sample confidence | on | re-run a holey scan under the old all-or-nothing gating |
| Finer room detail | **off** | A/B the 28 mm geometry floor |
| RealityKit preview | **off** | A/B the renderer on the shaded orbit |
| Adaptive reconstruction | off | the unwired variable-resolution path |
| Boolean detail | standard | Studio CSG lattice |

---

## 8. If Tier 3.3 still gets done

The argument for moving these into one `ScanTuning` type is discoverability, which
this document now provides at zero risk. If it is done anyway:

- Move values, never edit them in the same commit — a numerically neutral refactor
  is reviewable, a mixed one is not.
- Assert every value in a test, so a typo in the move cannot survive.
- Keep the *rationale comments* at the point of use, or move them too. They are the
  expensive part; six of them encode a device regression that already happened.
