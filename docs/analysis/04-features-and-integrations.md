# 04 · Feature Modules & Integrations

_Everything beyond the core scan pipeline. Worktree HEAD `e20dbfb`._

**Verdict:** a broad, unusually polished feature surface. Model Studio, Live Depth,
RoomPlan and the export suite are at or near best-in-class, with lots of hard-won
device knowledge baked in. The pre-App-Store must-dos are narrow: the missing Live
Activity, verifying Object Capture on a real device, the privacy manifest (see
[06](06-appstore-readiness.md)), and one small widget bug.

## Live Activity / Dynamic Island — DOES NOT EXIST (confirmed)

Exhaustive search for `ActivityKit` / `NSSupportsLiveActivities` / `ActivityAttributes`
/ `ActivityConfiguration` across the app and widget returns **zero matches**. The
Dynamic Island shows nothing because nothing was built — the home-screen widget
that was just added is a *WidgetKit* widget, which is a different thing.

**What's already in place to build on:** the widget extension is a fully-wired
WidgetKit target sharing App Group `group.com.keks.MagicCamera`, and `ScanRecorder`
already exposes an `onProgress` count callback (used at `RoomPlan/RoomPlanScan.swift:97`).

**To add a scan-progress Live Activity:**
1. `struct ScanActivityAttributes: ActivityAttributes` with a `ContentState`
   (progress fraction, point/triangle count, phase) in a file compiled into
   **both** targets (like `MagicCamera/Widget/WidgetShared.swift`).
2. `NSSupportsLiveActivities = true` in `MagicCamera/App/Info.plist` (absent today).
3. An `ActivityConfiguration` in `MagicCameraWidgetBundle.body`
   (`MagicCameraWidget.swift:66`) with `.dynamicIsland { … }` compact/minimal/expanded regions.
4. App lifecycle: `Activity.request` on scan start, throttled `.update` from the
   recorder progress callback (ActivityKit rate-limits), `.end` on finish/cancel.
   Hook into `SpatialScanViewModel`; the RoomPlan feed is a second candidate.
5. iOS 16.1+ (target is 17 → fine).

This is the single most impactful feature-level opportunity and the user's explicit ask.

## Model Studio — `Studio/` — ⭐ flagship, best-in-class

Two ways to build/edit models: **Assistant** (natural language → on-device Apple
Intelligence / FoundationModels via **14 self-validating tool calls** —
add/move/place/rotate/scale/recolor/duplicate/delete/smooth/reduce/combine/mergeAll/
describe, `ModelStudioEngine.swift:226`) and **Manual Tools** (primitive palette
with analytic normals, per-axis nudge/rotate, scale, 13-colour palette, boolean
**CSG** union/subtract/intersect, plus direct-manipulation viewport gizmos).

Robustness is very high: 8-deep **undo**, **autosave + crash recovery** (1.5 s
debounce + immediate flush on background), two persistence formats (editable
`.mcstage` + flattened `.mcmesh`), **texture survives topology changes** (re-bake
after smooth/reduce/CSG), an honest tool contract (`[stage now: …]` facts line so
the model plans against reality), graceful degradation below iOS 26, and real test
coverage.

**Gaps:** CSG resolution fixed at 96 cells (large models lose detail through a
boolean; no user control); **no redo** (only undo); `chatSessionStorage` is `Any?`
type-erased (availability-guard necessity). **Recs:** add redo; expose a CSG
quality tier; a "building…" Dynamic-Island indicator for long multi-part builds.

## RoomPlan — `RoomPlan/` — very complete

Apple RoomPlan guided capture, extended beyond the stock sample with: **multi-room
merge** (app-owned `ARSession` sharing world space), **hybrid LiDAR point capture**
(depth polled at 12.5 Hz and fused during the walkthrough), and **texture baking**
of the parametric room from walkthrough photos. USDZ export falls back
`.parametric`→`.mesh`; parametric elements become a classified `MeshData` so a saved
room behaves like any scan.

**Gaps:** device-only (`#if canImport(RoomPlan)`) so not sim-verifiable; the 12.5 Hz
`currentFrame` polling competes with RoomPlan's own pipeline — worth a device check
under sustained multi-room scans on a thermally-throttled device; a duplicated
`dateStamp()` vs `FileStore.timestampedName` (minor DRY).

## Object Capture — `ObjectCapture/` — excellent code, ⚠️ UNVERIFIED (App Store risk)

Full guided RealityKit `ObjectCaptureSession` → `PhotogrammetrySession` → photo-real
USDZ, with unusually careful device-pitfall handling: releases the capture session
before reconstruction (avoids GPU/ANE starvation), caps the image set to 160
(strided hardlinks), shares a checkpoint dir, a two-stage stall watchdog
(2.5 min reassure / 9 min cancel / 10 min force-unfreeze), background-task +
idle-timer keep-alive, tmp sweeps, honest terminal-state mapping.

**⚠️ HIGH RISK:** the file header states it **could not be build-verified** —
`ObjectCaptureSession` is absent from the simulator SDK. This is an entire
user-facing module that has **never compiled in this environment or been verified on
device**. A typo or API drift ships as crash-on-entry. **Mandatory before
submission: device build + one full capture→reconstruct→save run.**

## Live Depth — `LiveDepth/` (20 files) — best-in-class breadth

Depth-effects camera (Raw/Heatmap/Bokeh/Relight/Portrait/Color Pop/Cinematic + tone
grade + named Photo Looks; relight aimed by dragging the preview) plus a serious
tool suite: photo (with measurement overlay), silent video, subject cutout to
transparent PNG, **RGBD export** (color.jpg + 16-bit-mm depth.png + intrinsics json —
DCC/CV-grade, correctly shared via Files), **3D wiggle** parallax video, dimension
export, tap-to-place **measure** polyline (distance + enclosed area via Newell's
method), and live Vision object detection + dimension scanner + text/QR reader.

Heavy work is off-main; degrades on non-Pro devices. **Gaps:** dead shader branches
(harmless); no golden-file tests for the subtle RGBD pixel-format/orientation logic.

## AR viewer / AR Quick Look — solid

Standalone AR viewer reuses the gallery as picker, exports the pick to a temp USDZ
off-main inside an `autoreleasepool` (avoids the documented off-main ModelIO
over-release crash). AR Quick Look is *presented* from an invisible host so QL's
native Done button works. USDZ correctness is hard-won: textured path emits explicit
reversed-winding back-faces (AR QL ignores `doubleSided`) with `.constant` unlit
shading (atlas is pre-lit); untextured uses `SCNScene.write` (ModelIO USDZ is
rejected by AR QL). No significant gaps.

## Export formats — comprehensive & robust

PLY (pure Foundation, tested) · USDZ points · USDZ/OBJ/STL mesh (SceneKit) · **GLB**
(hand-rolled glTF 2.0, tested) · textured GLB/USDZ (embedded PNG atlas, mipmapping
off to stop chart bleed) · **self-contained web viewer** (HTML + bundled three.js
r147, orbit+walk, in-page measurement, eye-dome lighting) · turntable MP4 ·
**floor-plan PDF** (A4, dimension lines, scale bar, area — genuinely professional).

**Gap (LOW):** if the bundled `WebViewerRuntime.js` is ever missing, the exporter
silently falls back to a **unpkg.com CDN** (`WebViewerExporter.swift:72`) — the
"self-contained" HTML would then require internet. Make that fallback fail loudly or drop it.

## New integrations (iCloud / widget / sharing / deep links)

- **iCloud Drive sync** (`Core/CloudStore.swift`) — well-designed single-point
  integration; see [01-architecture](01-architecture.md). **Gaps:** (1) the comment
  at `CloudStore.swift:267` claims `mirroredDestination` is "unit-tested" but **there
  is no CloudStore test** — false comment, add the test or fix the comment;
  (2) migration silently swallows per-file errors — a partial migration splits the
  library across local+cloud with no user signal.
- **Home-screen widget** — app publishes a `RecentScansSnapshot` + thumbnails into
  the App Group; widget reads it. **🐛 BUG (MEDIUM, regression in this commit):**
  gallery **delete doesn't refresh the widget** — `ScanGalleryView.delete(_:)`
  (`ScanGalleryView.swift:269`) mutates the local array but does **not** call
  `reload()`/`RecentScansPublisher.publish()` like save/rename/favourite do, so a
  deleted scan lingers in the widget (with a possibly-broken thumbnail) until the
  next publish. One-line fix.
- **Per-scan deep link (LOW):** `RecentScan.id` is documented as a "deep-link key"
  but no `magiccamera://scan/<id>` route exists — tapping a widget tile opens the
  gallery, not that scan. Implement the advertised route.

## App Intents / Siri — `App/AppShortcuts.swift` — partial

Only 2 of 5 destinations exposed (Spatial Scan, Live Depth). **Object Capture, Room
Plan, Model Studio have no intents** despite being first-class home modes. Adding
three more is trivial and broadens Siri / Shortcuts / Spotlight coverage.

## Prioritized opportunities

1. **Scan-progress Live Activity / Dynamic Island** — user's explicit ask; nothing exists; host + progress hook already in place.
2. **Build & device-verify Object Capture** — untested module, ship-blocking if broken.
3. **Add `PrivacyInfo.xcprivacy`** — see [06](06-appstore-readiness.md).
4. **Fix widget staleness on delete** — one-liner in `ScanGalleryView.delete`.
5. **Expose the remaining 3 App Intents.**
6. **Per-scan widget deep link** (`magiccamera://scan/<id>`).
7. Polish: web-viewer CDN fallback fail-loud; add CloudStore test (or fix the false
   comment) + surface partial-migration failures; RGBD golden tests; Studio redo + CSG tier.
