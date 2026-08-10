> **REFERENCE — subsystem description, written 2026-07-24.** The mechanics
> are still accurate; any *status* claim inside is dated and several have
> since shipped. Current status: [07-roadmap](07-roadmap.md), verified
> 2026-08-10.

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

Done by hand — the delegated audit hit the session limit three times. Narrower
than planned, but everything below is checked against the code.

**First, what is NOT true.** There are no empty action closures anywhere in the
app, no `TODO`/`FIXME` in any Swift file, and no control gated on a condition that
is always false. Settings ▸ Variable-resolution surfaces was the strongest
candidate for a toggle that does nothing — its implementation is the never-wired
adaptive stack — but it does reach real code
(`SpatialScanViewModel+Reconstruction.swift:90,498`, `+Export.swift:162`). So
"parts of the menu do nothing" is not literal dead buttons. It is this:

| # | finding | evidence |
|---|---|---|
| 1 | **Two home-screen entries open the same screen with a different preset.** "Spatial Scan" is `startSpatialScan(profile: .room)`; "Quick 3D" is `startSpatialScan(profile: .object)`. Same view, same code path. And since the capture picker is now Subject × Detail, the home screen asks a question the very next screen asks again — the first segment of the picker *is* that choice | `RootView.swift:41-46` vs `:57-62` |
| 2 | **`cube.transparent` means four different things.** The app's own brand mark, "Spatial Scan", "Quick 3D" — two of those sit in different groups on the same screen — and "Send to Studio" in the review bar | `RootView.swift:44,61`, `:274` (BrandMark), `SpatialScanView.swift:946` |
| 3 | **Live Depth is a mode that leads nowhere.** The code says so itself: "makes no scan and feeds nothing downstream — it's a camera effect". It is demoted but still a top-level destination, and it is the only one whose output cannot enter the library, Studio, or an export | `RootView.swift:96-102` |
| 4 | **Seven destinations, four card treatments, six bespoke gradients** with hardcoded RGB and no shared palette. Colour is decorative rather than semantic — nothing about the hue tells you what a tile does, so the screen reads as a template of tiles rather than as a product with a point of view | `RootView.swift:41-102`, `ModeCard` / `CompactModeTile` / `PlainToolRow` |

**The bottom bar** (`SpatialScanView.reviewControls:772`) — the complaint is real
and locatable. It stacks four rows in one glass panel, plus up to a 300 pt drawer,
over the 3D view it exists to let you look at:

| # | finding | evidence |
|---|---|---|
| 5 | **No hierarchy.** `presetRow` — four camera-view buttons, a convenience — sits at the TOP of the bar, and each button gets the same `Theme.surface` treatment and the same full-width flex as everything else. The only accent in the entire bar is Export. **Save, the action that prevents losing work, looks exactly like a camera preset** | `SpatialScanView.swift:906-921`, `:958` |
| 6 | **Four classes of action at equal weight in one row**: a persistent view toggle (auto-orbit), two navigations (AR, Studio), two terminal actions (Save, Export) | `:923-980` |
| 7 | **Two icon-only buttons with no visible label** — `arkit` and `cube.transparent`. They carry accessibility labels, so VoiceOver is fine, but sighted users get a glyph that does not read as "Model Studio" | `:935`, `:946` |

Not covered: Model Studio's own controls, the gallery's context menus, and the
Capabilities screen. Those remain unaudited — do not read their absence here as a
pass.

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

Partial, done by hand after the delegated audit failed three times. **Only the
submission-critical checks were completed** — the service-layer error handling,
storage, and data-safety passes are still outstanding.

**Verified present** (so nobody re-checks these): `MARKETING_VERSION 1.0.0` /
`CURRENT_PROJECT_VERSION 1`; bundle ids `com.keks.MagicCamera` and
`.Widget`; a privacy manifest for **both** targets (`MagicCamera/App/PrivacyInfo.xcprivacy`,
`MagicCameraWidget/PrivacyInfo.xcprivacy`); `ITSAppUsesNonExemptEncryption = false`;
`NSSupportsLiveActivities = true`; `NSCameraUsageDescription` and
`NSPhotoLibraryAddUsageDescription`, both written in plain language.

| severity | finding | evidence |
|---|---|---|
| SHOULD-FIX | **Developer jargon reaches the UI.** "Object+ (2 mm voxels)" is a control label on the capture screen. "How finely joins, carves and intersections are resampled" and the diagnostics footer's "⚡︎ GPU / ○ CPU lines" are Settings copy. A user does not know what a voxel is, and does not need to | `SpatialScanView.swift:458`, `SettingsView.swift:67`, `:206` |
| NICE | `NSPhotoLibraryAddUsageDescription` is present without the read variant. Correct **if** the app only ever writes — the one photo-library file is `LiveDepth/MediaSaver.swift` and no `PHPicker`/`PHAsset` read exists, so this is fine today. It becomes a submission failure the moment anything imports from the library | `MagicCamera/App/Info.plist:90` |

**Not checked, still open:** permission-denied paths and whether any route into
Settings exists; silent failures in the service layer (`try?`, empty `catch`);
data-safety review of the stores; the storage screen's disk-full behaviour; the
no-LiDAR and no-Apple-Intelligence degradation paths. These need a fresh run.

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

2. **Guarded `removingSmallComponents`** the way `removeStrayClusters` already
   was: it now declines rather than keeping less than half the triangles, and says
   so on the `component trim` breadcrumb. Six call sites made safe at once — the
   only one of the five collapse points that destroyed geometry the user never
   chose to discard.

### Next, in order

3. **Home screen: merge the two Spatial Scan entries.** Finding 2a-1 — they open
   the same screen and the difference between them is now the first segment of the
   picker on that screen. One entry, and let the picker do its job. This also frees
   the duplicated `cube.transparent` glyph (2a-2).

4. **Bottom bar: give it a hierarchy.** Findings 2a-5..7. Concretely: move the
   camera presets into the tools drawer or a compact segmented control, accent
   Save (not only Export), and separate the persistent toggle from the terminal
   actions. Do not redesign it wholesale — the parts work, the ordering and weight
   do not.

5. **Decide what "multi-object" should mean before writing any more of it.** Two
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

6. **Finish the production-readiness audit.** §2c covers only the submission
   blockers. Permission-denied paths, silent service-layer failures, data safety in
   the stores, disk-full behaviour and the no-LiDAR / no-Apple-Intelligence
   degradation paths are all still unchecked.

7. **Object isolation quality** ("isn't great either"). r74 removed the size floor
   that cost thin subjects 98 % of their points, but that is unverified on device.
   Measure before changing anything else here: the `isolate funnel` breadcrumb
   already reports `→ mask → hull → cluster N`.

8. **Live Depth: keep or cut.** It is a top-level destination whose output cannot
   enter the library, Studio or an export — the code says as much itself. Cutting
   it removes a whole menu entry and a mode's worth of maintenance before 1.0;
   keeping it needs a reason a user would recognise. The user's call.

9. **Plain-language pass over the UI copy.** "Object+ (2 mm voxels)", "how finely
   joins, carves and intersections are resampled", "⚡︎ GPU / ○ CPU lines".
