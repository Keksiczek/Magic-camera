# Roadmap — verified 2026-08-10

**Rewritten from scratch, not updated.** The previous version opened with a
warning that it had been stale since 2026-07-27, and it was still being used to
plan work: of ten priorities on its front page, eight were already shipped. Every
line below was checked against the code on
`claude/cloud-mesh-postprocess-optimize-8cb455` at `2b5a528`, and the evidence is
recorded so the next reader can redo the check rather than trust it.

Direction, and the ranking used to order this: **[VISION.md](VISION.md)**.

---

## Where the app actually is

| | |
|---|---|
| App code | 182 Swift files, 44,515 lines |
| Tests | 49 files, 7,703 lines — **429 tests, 0 failures**, 1 skipped |
| Branch | 356 commits, never merged to `main` |
| Device verification | **none of this branch** |

That last row is the most important fact on this page.

## Already done — do not re-plan these

Checked present today, so nobody spends another round rediscovering them:

| Old item | Evidence |
|---|---|
| Privacy manifest | `App/PrivacyInfo.xcprivacy` + the widget's |
| Memory-pressure governor | `Core/MemoryPressureMonitor.swift`; `SpatialScanView` and `ModelStudioView` both act (shed undo history, cancel in-flight work at `.critical`) |
| Discard confirmation | confirmation dialog on "New" in `SpatialScanView` |
| `ITSAppUsesNonExemptEncryption` | `App/Info.plist` |
| Multi-page atlas | live — `ChartAtlas.build(maxPages:)`, budget from `affordablePageBudget` |
| Live Activity / Dynamic Island | `SpatialScan/ScanLiveActivityController.swift` + `Widget/ScanActivityAttributes.swift` |
| Widget staleness on delete | `ScanGalleryView.delete` → `RecentScansPublisher.publish()` |
| Per-scan deep link | `magiccamera://scan/<id>`, routed in `App/RootView.swift` |
| First-run onboarding | `App/OnboardingView.swift` |
| Studio redo | `ModelStudioViewModel.redo()` |
| "5 ops bypass `runOperation`" | all five route through it now |
| On-device AI | `SpatialScan/ScanIntelligence.swift` — Describe scan, Auto-fix |

---

## Tier 0 — Before anything else

### 0.1 Device-verify this branch · S (one session with a phone) · **BLOCKING**

356 commits, most of a scan pipeline rewritten, not one of them run on hardware
from this branch. Everything below is guesswork until this happens. After one
room and one object, read `Settings ▸ Diagnostics` in this order:

| Field | Must read | Guards |
|---|---|---|
| `scan quality — … snapped N` | **0** below 60% of cap | lattice rings (`d61eaaa`) |
| `scan icp — … tilt N°` | **0.00** | ICP levelling (`30e9f1b`) |
| `scan quality — raw A → kept B` | B ≥ ⅔ A | matte filter no longer eats furniture (`e1553e7`) |
| `surface cleanup — planes N` on an **Object** | **0** | subjects not flattened (`e1553e7`) |
| `texture-bake — repaired N/M` vs `bake budget — pages ≤ P` | repaired ≪ M | atlas/triangle reconciliation (`1aa4c44`) |
| `scan metrics — …` | present and plausible | new in `2b5a528` |

Two are already confirmed from the 2026-08-10 export: `tilt 0.00°` on all four
scans, and a room mesh whose floor measures 0.03° off level (was 2.78°).

### 0.2 Device-verify Object Capture · S · **BLOCKING**

Never compiled in the simulator, never run. Crash-on-entry is plausible and would
be a first-launch review failure.

### 0.3 Merge this branch · S

356 commits nobody else can see is not a state to ship from. Blocked on 0.1 and
0.2, and on nothing else.

---

## Tier 1 — Finish what r88 started

From measured artefacts, not from reading code. Each names the number that would
say it worked. Background: **[HANDOFF-r88.md](HANDOFF-r88.md)**.

### 1.1 Re-measure the holes, then close them · M

The r88 room finished with **17,757 open edges**. Deliberately not chased then:
both capture faults fixed that round produce holes — the matte filter alone was
deleting half the cloud — so the number should move on its own. Re-measure
first; tune `MeshHoleFiller` only against a room captured with the fixes.

### 1.2 Isolation hands the reconstruction fragments · M

`isolate funnel — 28962 → mask 18740 → cluster 1174` on a lamp: the guard at
`max(800, working.count / 20)` let a 6% fragment through by 237 points, and the
comment directly above that guard describes this exact failure from an earlier
round. The planar gate now blocks the *consequence*, but the fragment still
reaches the mesher. Changing 1/20 to another fraction is guessing — the
measurement that settles it is whether the kept cluster is a pancake, which needs
the isolated cloud to be exportable. **Add that debug export first.**

### 1.3 Texture density on rooms · M

`1aa4c44` caps triangles by what the atlas can photograph, which should bring
`repaired` down from 59%. If it does not, the next lever is chart shatter —
44,248 charts for 531k triangles, median 12 px — and *not* more pages, which cost
~865 MB each.

### 1.4 Peak memory on the room path · M

3,144 MB peak, **231 MB headroom**, four `critical` events in one room. The
monitor exists and reacts; what is missing is not spending the memory in the
first place. The capture cloud, its fusion cells and its view directions are all
still resident during the bake. Releasing what the bake does not need is the
cheapest win, and 1.3 already shrinks the mesh it works on.

### 1.5 Revisit the 28 mm geometry floor · M

Justified when registration noise was ~16 mm. ICP now reports 2–4 mm mean
corrections and a level floor, so the floor may be costing detail it no longer
buys. Flag-gated A/B against real exports — never a blind change.

---

## Tier 2 — Product completeness

### 2.1 Localisation · M

There is none: no `.lproj`, every string hardcoded English, in an app whose
author and first users are Czech. This is the widest gap between the app and its
audience, and nothing else on this page delivers more user-visible value per unit
of work.

### 2.2 Accessibility pass · S–M

40 `accessibilityLabel` sites across 182 files, and the custom camera and review
chrome is where they are missing. Dynamic Type on those surfaces is untested.

### 2.3 Put the measurements to work · S

`ScanMetrics` (new in `2b5a528`) knows every scan's footprint, height and kind,
but only the name and the Measurements sheet use it. The gallery still lists
point counts; sorting and filtering by size or kind is now a small change.

### 2.4 Submission mechanics · S

The code half is done. What remains is not code: final name, bundle id,
screenshots, App Store Connect record, version 1.0.0.

---

## Tier 3 — Architecture, alongside features

Not a big-bang refactor. Six files break the project's own 800-line rule:

| File | Lines |
|---|---|
| `SpatialScan/ScanRecorder.swift` | 1,909 |
| `SpatialScan/SpatialScanViewModel.swift` | 1,784 |
| `SpatialScan/ScanARView.swift` | 1,241 |
| `SpatialScan/PhotoTextureBaker.swift` | 1,236 |
| `SpatialScan/SpatialScanView.swift` | 1,022 |
| `Studio/ModelStudioViewModel.swift` | 999 |

`ScanRecorder` is the one worth splitting on merit rather than on line count:
capture, fusion, carving, ICP and coverage are five separable concerns sharing
one queue.

`SpatialScanView`'s review drawer threads **16 bindings three levels deep**, and
that file has already hit a SwiftUI type-metadata limit once. Give a new sheet a
small nominal View owning its own `@State` — `ScanMeasurementsButton` is the
pattern — rather than a seventeenth binding.

---

## Tier 4 — After 1.0

- **SceneKit → RealityKit.** Soft-deprecated and working. An epic, not urgent —
  but it decides the shape of the viewer layer, so don't build much more on
  SceneKit meanwhile.
- **Object Capture as a first-class route** for the small objects where LiDAR is
  weakest, rather than a mode the user has to go and find.
- **Control Widget "Start scan"**; Swift 6.2 approachable concurrency.

---

## How to keep this file honest

Add an item with the evidence that it is missing; delete it with the evidence
that it landed. The previous version rotted because items were added from
intention and never removed from fact — which cost this round a full audit before
any work could start.
