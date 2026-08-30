# r89 — the device round this branch has been waiting for

**Nothing on this branch has ever run on hardware.** 358 commits, most of a scan
pipeline rewritten. This document is the pre-round state, the test script to run
on the phone, and the list of what to send back. Written 2026-08-30 against
`32f14d6`.

Background: [HANDOFF-r88.md](HANDOFF-r88.md) (what was measured and fixed),
[07-roadmap.md](07-roadmap.md) (what is open), [VISION.md](VISION.md) (why).

---

## 1. What is open, half-done or broken

### A. Blocking

| # | Thing | State |
|---|---|---|
| A1 | **The whole branch is device-unverified** | 5 of the r88 fixes have never been seen on hardware; 2 are already confirmed from the 2026-08-10 export (`tilt 0.00°`, floor 0.03° off level) |
| A2 | **Object Capture has never been run** | never compiled in the simulator either. Crash-on-entry is plausible and would be a first-launch review failure |
| A3 | *(withdrawn — this host builds Metal apps fine)* | Three different CLI build failures here were all **transient**, none of them the code: `cannot execute tool 'metal' due to missing Metal Toolchain` (the toolchain is installed, on an on-demand disk image under `~/Library/Developer/DVTDownloads/MetalToolchain/mounts/`, not yet attached when the build started); a `swift-frontend` crash in `clang::Sema::DefineUsedVTables()` precompiling the **UIKit** PCM for the **x86_64** simulator; and `The Xcode build system has crashed. Build again to continue.` on `CompileMetalFile`. **Retry, and prefer a device destination with a private `-derivedDataPath`** — that build succeeded on the second attempt and does not touch Xcode's own caches |

### B. Faults that were measured and are still open

| # | Thing | The number that is waiting |
|---|---|---|
| B1 | **Holes** | the r88 room finished with **17,757 open edges**. Deliberately not chased — both capture fixes produce holes, so the number should move on its own. **Re-measure before touching `MeshHoleFiller`** |
| B2 | **Isolation hands the mesher fragments** | `max(800, working.count / 20)` let a 6% fragment through by **237 points**. The planar gate blocks the consequence, not the cause. *Now measurable from the export — see §2* |
| B3 | **Room texture density** | 59% of a room's texture was *synthesised*, not photographed. `1aa4c44` caps triangles by what the atlas can pay for; unverified. Next lever if it fails is chart shatter (44,248 charts, 12 px median), **not** more pages — those cost ~865 MB each |
| B4 | **Peak memory** | 3,144 MB peak, **231 MB headroom**, four `critical` events in one room. The monitor reacts; nothing avoids spending the memory. Capture cloud, fusion cells and view directions are all still resident during the bake |
| B5 | **The 28 mm geometry floor** | justified when registration noise was ~16 mm. ICP now reports 2–4 mm. The floor may be costing detail it no longer buys — A/B against real exports, never a blind change |

### C. Built, tested, and not switched on

| # | Thing | State |
|---|---|---|
| C1 | **Variable-resolution reconstruction** | `AdaptiveOctree.partition` + `AdaptiveMesher` + `AreaProportionalAtlas` all exist and are tested, all isolated from the live uniform path. Wiring is a device-proven job behind a flag. T-junction cracks are the known open problem. `adaptiveDecimate` was dropped — it blurred walls |

*(The multi-page atlas is **no longer** dormant — `ChartAtlas.build(maxPages:)` is live and its budget comes from `affordablePageBudget`. Any note saying otherwise is stale.)*

### D. User-visible gaps

| # | Thing | Measured today |
|---|---|---|
| D1 | **Czech stops at the first thing that happens** | 209 keys ship and the menus are translated, but **107 of 109 `showToast` string literals have no Czech key**, and a further **30 toast call sites are not literals at all** (interpolated or variable), so they can never be keyed. The app speaks Czech until it has something to tell you |
| D2 | **Accessibility** | ~40 `accessibilityLabel` sites across 182 files, and the camera and review chrome is where they are missing. Dynamic Type untested there |
| D3 | **The measurements are not used** | `ScanMetrics` knows every scan's footprint, height and kind; only the name and the Measurements sheet read it. The gallery still lists point counts |
| D4 | **Submission mechanics** | not code: final name, bundle id, screenshots, App Store Connect record, 1.0.0 |

### E. Structural, not urgent

Six files over the project's own 800-line rule (`ScanRecorder` 1,909;
`SpatialScanViewModel` 1,784; `ScanARView` 1,241; `PhotoTextureBaker` 1,236;
`SpatialScanView` 1,022; `ModelStudioViewModel` 999). `SpatialScanView` has
already hit the SwiftUI type-metadata limit once. SceneKit is soft-deprecated
and working — an epic, not a task.

---

## 2. What the export can answer that it could not before

Three fields were added this round (`ScanShapeReport`), each because a question
cost a round to answer by hand off the user's files:

| Field | Appears on | Answers |
|---|---|---|
| `bbox A×B×C · thin R` | every `isolate funnel` line, `scan finished — mesh` | **B2.** `thin` is shortest ÷ longest extent; under ~0.15 is the pancake `isFlat` refuses. The r88 lamp was `108×125×1 mm · thin 0.008` and the export said nothing |
| `y lo→hi m · a/b/c/…%` | `prep funnel`, `scan finished — points`, `scan finished — mesh` | **"which step deleted my table".** Compare the cloud's height profile with the mesh's — the band that empties names the loss |
| `thermal nominal…critical` | `scan config`, `scan finished — points` | ARKit sheds depth frames under thermal pressure long before the phone feels hot |

**Compile-verified**: `BUILD SUCCEEDED` for `generic/platform=iOS` (arm64,
`Debug-iphoneos`) on this host. Not run on a phone — that is what §3 is for.

---

## 3. The device script

Run in this order. It is about 20 minutes and produces everything §4 asks for.

### Scan 1 — a room, Room profile

1. Start the scan, sweep the room normally, **include a table or a desk**.
2. Let it finish, then run **Surface**.
3. Then run the texture bake and export the room as **USDZ**.

Read in `Settings ▸ Diagnostics`:

| Line | Must read | Guards |
|---|---|---|
| `scan quality — … snapped N` | **0** (unless the scan went over 60% of its cap) | lattice rings, `d61eaaa` |
| `scan icp — … tilt N°` | **0.00** | ICP levelling, `30e9f1b` |
| `scan quality — raw A → kept B` | **B ≥ ⅔ A** | the matte filter no longer eats furniture, `e1553e7` |
| `prep funnel … y …%` vs `scan finished — mesh … y …%` | no band collapses to 0 | *new* — B1/B2 |
| `texture-bake — repaired N/M` vs `bake budget — pages ≤ P` | repaired ≪ M | atlas/triangle reconciliation, `1aa4c44` |
| `surface holes — … open edges` | **write the number down** | B1 — this is the re-measurement |
| `memory pressure` | how many `critical` | B4 |
| `scan config — … thermal` | note it | *new* |

### Scan 2 — a single object, Object profile

An object with thin structure is the interesting case (a lamp, a chair, glasses).

4. Scan it, tap the subject, run **3D model**.

| Line | Must read |
|---|---|
| `surface cleanup — planes N` | **0** — an Object scan with planes was flattened |
| `isolate funnel — … bbox … thin R` | **thin > 0.15** — under it, B2 just reproduced |
| `scan quality — … snapped N` | **0** |
| `scan metrics — …` | present and plausible |

### Scan 3 — Object Capture (A2)

5. Open the Object Capture route and take it as far as it goes. **A crash here is
   the finding**; nothing else about it is known.

### Along the way

6. Watch for **English toasts** (D1) — every one you see is a missing key.
7. Background the app mid-reconstruction once (watchdog check).

---

## 4. What to send back

| Send | Why |
|---|---|
| **The diagnostics export**, after all three scans | the whole of §3 is read from it |
| **The room's `.mcscan`** *and* its exported **USDZ** | r88's method: measure the artefacts, not the code. Cloud + mesh is what makes the height-profile comparison decisive |
| **The object's USDZ** | the pancake test, independent of the export |
| **Screenshots of anything visibly wrong** | rings, holes, smeared texture, an English toast |
| **Crash reports**, if the app dies | `~/Library/Developer/Xcode/DeviceLogs` after a sync, or MetricKit picks them up into the same export |

**Do not send a description instead of a file.** Every fix on this branch that
held up started from a number taken off a real artefact; every one that had to be
reverted started from reading the code.
