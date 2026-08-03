# UX and production-readiness audit

_Started 2026-08-02 (r79), from the user's own report. Findings are recorded here
as they are confirmed; the plan at the end is what to do about them._

The user's words, which this document exists to answer:

> "we still have menu UX that partly does nothing, isn't unique · multiple objects
> don't work even when I click them myself in spatial scan · the selection in
> spatial scan is still confusing — maybe I pick what I want to scan and what
> quality, plus bonus functions · the current bottom bar is nothing special ·
> object isolation isn't great either · is the rest of the app finished and
> consistent, what else is needed for production ready"

---

## 1. The capture picker is two axes pretending to be one

**Confirmed, with the code admitting it.** `CaptureQuality`
(`MagicCamera/SpatialScan/CaptureQuality.swift:98`) is a flat five-way enum —
Draft, Balanced, Max, Object, Room — presented as one `Picker` over `allCases`
(`SpatialScan/SpatialScanView.swift:368`). Its own comment says what is wrong:

> "Object and Room have no four-tier equivalent, so they **borrow existing slots**."
> — `CaptureQuality.swift:106`

Those five cases are drawn from two independent questions:

| axis | what it decides | today's cases |
|---|---|---|
| **what you are scanning** | capture range, voxel size, distance coarsening, carve strength, silhouette-edge threshold, whether ARKit scene mesh and planes are captured, auto-framing | Object (`objectConfig`, ≤2.5 m, 3 mm, no coarsening, edge 0.04), Room (`roomConfig`, 7 m, 12 mm, coarsening on, carve 1.0, edge 0.12), and an unnamed third — the `default:` branch, edge 0.09 |
| **how well** | point budget, mesh detail tier, reconstruction method | Draft (`.fast` / `.voxel`), Balanced (`.balanced` / `.smooth`), Max (`.ultra` / `.fusion`) |

Because they share one control, the two axes are welded: Object is pinned to
`.ultra` + fusion, Room to `.detailed` + fusion. **"A room, quickly" and "an object,
roughly" are not expressible.** That is the confusion, exactly.

It gets worse below the picker. Object mode grows two further knobs that exist
nowhere else and are not in the enum at all — `objectFine` (the 2 mm "Object+"
density) and an `objectRange` slider — routed through a separate
`objectConfig(fine:rangeMeters:)` call in the view model
(`SpatialScanViewModel.swift:185`) and surfaced as a conditional toggle and slider
(`SpatialScanView.swift:467`, `:475`). So the real model is: one control holding
two axes, plus a third axis and a continuous parameter that appear somewhere else
when one particular value is selected.

### Proposal — the user's own instinct, made concrete

Three controls, each answering one question:

```
Subject   ( Object | Room | Scene )      ← picks the ScanConfig family
Detail    ( Quick  | Balanced | Max )    ← picks the density / method tier
Extras    (disclosure, contextual)       ← Object+ density, range, photo texture, …
```

- **Nothing new has to be tuned.** Subject selects between the three configs that
  already exist (`objectConfig`, `roomConfig`, the `default:` branch — "Scene" is
  the honest name for the one that has never had one). Detail selects the density
  and method tiers that already exist. The composition is mechanical.
- **Migration is total**: draft/balanced/max → Scene × the matching detail;
  object → Object × Max; room → Room × Balanced. Every current setting has an
  exact new address, so no existing user's behaviour changes.
- **Nine combinations instead of five, and four of them are new** — Object × Quick,
  Object × Balanced, Room × Quick, Room × Max. They are compositions of tested
  pieces, but the combinations themselves have never run on a device. They need a
  device pass before this is defaulted on.
- **Extras stop being a surprise**: Object+ and range belong under a disclosure
  next to the Subject that owns them, not as controls that materialise elsewhere.

_Status: proposed, not implemented. Needs the user's agreement on the three
Subject names before it is worth writing._

---

## 2. Findings from the parallel audits

_Three read-only audits were run over the UI surface, the multi-object path and
production-readiness. Their results are recorded below as they land._

### 2a. Dead, duplicated and unreachable controls

_(pending)_

### 2b. Why multiple objects collapse into one

**Traced end to end. The answer is blunt: the scan pipeline has no representation
of "several objects" at all, anywhere, until Model Studio — and it never reaches
Model Studio as more than one.**

`PointCloud`, `MeshData` and `TexturedMesh` are flat buffers with no per-object id.
`subjectAnchor` is a single `SIMD3<Float>?`, `regionCenter` a single optional
sphere, `userIsolated` a single `Bool`. Every manual-selection entry point was
written against that single-subject premise, so there is no chain to fix — there
are **three independent doors, each of which alone reproduces the complaint**,
depending on which gesture the user reached for:

| # | where | what it does |
|---|---|---|
| 1 | `SpatialScanViewModel.swift:1538-1558` (`setScanTarget`) + `ScanRecorder.swift:56,532` | Tapping a second object calls `clearAccumulation()` and re-centres the one ROI sphere — **it deletes everything already captured of the first object**, at capture time |
| 2 | `SpatialScanViewModel+Cleanup.swift:429-436` (`applyLasso`) | A keep-inside lasso re-clusters what the user just enclosed and keeps **only the largest** cluster. One loop around two objects silently discards the smaller. There is no additive lasso |
| 3 | `PointCloudSegmenter.swift:230-351` (`isolateMainSubject`) | Single-subject by construction: one best cluster plus fragments within 1.8× its radius and no larger than it. That is a re-union rule for *one fragmented subject*; a genuinely separate second object is never in reach. Behind the "Isolate object" button and every auto path |

Then, downstream, a fourth hazard that would gut a second object even if 1–3 were
fixed:

| 4 | `MeshData.swift:511-577` (`removingSmallComponents`), called from 6 sites | Drops every connected component under a fraction of the **largest** component's triangle count, with **no floor guard** — unlike its point-cloud sibling `removeStrayClusters` (`PointCloudSegmenter.swift:208-223`), which explicitly refuses to act unless it keeps `max(200, count/2)` precisely so "a genuine multi-object scene is never gutted". Sites: `ReconstructionPipeline.swift:205`, `+Reconstruction.swift:140` and `:634`, `PhotoTextureBaker.swift:1059`, `+Editing.swift:36`, `SpatialScanViewModel.swift:1225` |

And the ceiling:

| 5 | `ModelStudioViewModel.swift:313-340` (`importMesh`) | Wraps the whole incoming mesh — however many disjoint components — into exactly **one** `StudioObject`. `StageStore.objects: [StudioObject]` is the only multi-object model in the app, and the scan → Studio bridge never puts more than one entry in it |

Ruled out, with evidence: `MeshPrimitiveSnap.spatialClusters` already fits each
separated object about its own axis; `MeshPlanarRegularizer` and `MeshHoleFiller`
work per loop / per plane and never weld two components; `ChartAtlas` has no
component logic; `MeshStore` would round-trip a multi-component mesh happily.

**So "multi-object" is not a bug to fix. It is a feature the data model was never
given** — and the user has been discovering that one gesture at a time.

### 2c. Production-readiness gaps

_Not completed — the audit and the dead-controls audit both hit the session limit
mid-run. To be re-run; nothing was concluded, so nothing here should be treated as
a clean bill of health._

### 2c. Production-readiness gaps

_(pending)_

---

## 3. Plan

Ordered by what buys the most per unit of risk. Items 1 and 2 are done; the rest
is proposed.

### Done

1. **Split the capture picker into Subject × Detail.** `CaptureProfile` +
   `CaptureProfilePicker`, with tests asserting the five old combinations are
   byte-identical. The four new pairs (Object or Room at a tier they never had)
   need a device pass before anyone trusts them.

### Next, in order

2. **Guard `removingSmallComponents` the way `removeStrayClusters` already is.**
   Smallest possible fix, six call sites made safe at once, and it is the only one
   of the five collapse points that destroys geometry the user never chose to
   discard. Give it the same floor: refuse to act if the result would keep less
   than half of what came in, and log when it declines. *No new concepts, no data
   model change.*

3. **Decide what "multi-object" should mean before writing any more of it.** Two
   honest options, and they are very different sizes:

   - **(a) Keep one mesh, stop destroying parts of it.** Fix doors 1–3 so a
     multi-object selection survives as one mesh with several disjoint components:
     an additive tap (a list of anchors, no `clearAccumulation`), an additive
     lasso, and an `isolateMainSubject` that keeps every cluster the user's
     selection actually touched. The result is still one object to the app, which
     is honest and much cheaper — the user gets both objects in the model and in
     the export, just not as separately draggable things.
   - **(b) Real multi-object.** Carry a per-component identity from selection all
     the way to `StageStore.objects`, so a scan can import as N `StudioObject`s.
     This is a data-model change across `PointCloud`, `MeshData`, the isolation
     path, the bake and the store — the largest single item on any current list.

   **Recommendation: (a) now, (b) only if the user actually wants separate
   manipulable objects rather than "everything I selected is in the model".** The
   complaint as stated ("multiple objects don't work even when I click them
   myself") is satisfied by (a).

4. **Re-run the two audits that died** — dead/duplicate controls and
   production-readiness. Both hit the session limit with nothing concluded, and
   the user's "menu UX partly does nothing" is still unverified.

5. **Object isolation quality** ("isn't great either"). r74 removed the size floor
   that cost thin subjects 98 % of their points, but that is unverified on device.
   Measure before changing anything else here: the `isolate funnel` breadcrumb
   already reports `→ mask → hull → cluster N`.

6. **The bottom bar.** Not yet assessed — it was the dead-controls audit's job.
   Assess before redesigning; the complaint is real but unlocated.
