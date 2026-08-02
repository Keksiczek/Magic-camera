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

_(pending)_

### 2c. Production-readiness gaps

_(pending)_

---

## 3. Plan

_(written once §2 is complete — the ordering depends on what the audits find.)_
