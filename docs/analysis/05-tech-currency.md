# 05 · Technology Currency & "Top-Tier" Benchmark

_Last updated: 2026-07-24. Benchmarks the app against what is technologically
possible on Apple platforms today (iOS 26 / Xcode 26 / Swift 6.2)._

The question this answers: **if we rebuilt each layer with the best Apple tech
available right now, what would change?** Each item is graded by how much it
would move the product vs. its cost. This is strategy input for the next rounds,
not a to-do list — pair it with [07-roadmap](07-roadmap.md).

Legend: 🟢 already current · 🟡 partially current · 🔴 on legacy tech.

---

## 1. Rendering stack — 🔴 SceneKit is soft-deprecated

**State of the art:** RealityKit is Apple's forward 3D engine (ECS architecture,
PBR/MaterialX, `RealityView` in SwiftUI, shared with visionOS). At WWDC 2025
Apple **soft-deprecated SceneKit** — maintenance/critical-bug-only, no new
features — and explicitly recommends RealityKit for new apps and significant
updates. SceneKit is not hard-deprecated; existing apps keep working.

**Where we are:** the app renders and exports almost entirely through SceneKit —
`MeshSceneBuilder`, `MeshViewer`, `ARViewerView`, `ModelStudioRenderer`, and USDZ
export via `SCNScene.write` (see [soup-mesh-weld-rule] and the USDZ-export note in
memory). This is the single biggest piece of "legacy" surface in the app.

**Recommendation (strategic, not urgent):** treat a **SceneKit → RealityKit**
migration as a major future epic, not a 1.0 blocker. RealityKit would bring
better materials, `RealityView`, visionOS reach, and a supported future. But it
is a large rewrite of the viewer/Studio/AR layers with its own risks, and USDZ
export via SceneKit currently works and is AR-Quick-Look-valid. **For 1.0: stay
on SceneKit.** Plan the migration as a dedicated track once the pipeline/UX are
locked. Do not scatter RealityKit in piecemeal.

## 2. Design language — 🟡 custom glass vs. native Liquid Glass

**State of the art:** iOS 26's **Liquid Glass** — a dynamic material with real
blur/refraction/specular that reacts to touch. Native APIs: `.glassEffect()`,
`GlassEffectContainer`, `.buttonStyle(.glass/.glassProminent)`, `glassEffectID`
morphing, and `widgetAccentable()` / accented rendering for widgets.

**Where we are:** a hand-rolled `glassPanel()` / `PressableCardStyle` design
system (see [03-ux-and-design](03-ux-and-design.md)). It looks intentional, but
it is a static approximation of a material the OS now renders natively.

**Recommendation:** adopt native Liquid Glass on the primary chrome (home cards,
toolbars, HUD, the new widget) **behind `if #available(iOS 26)`**, keeping the
`glassPanel` fallback for iOS 17–25. This aligns the app with the current OS
look, gets interactivity/accessibility/morphing for free, and future-proofs. High
visual ROI, medium effort. Details and the deployment-target trade-off in
[03-ux-and-design](03-ux-and-design.md).

## 3. Capture & reconstruction — 🟢/🟡 modern, with headroom

**State of the art:** ARKit `sceneDepth`/`smoothedSceneDepth` + scene mesh
(LiDAR); RealityKit **Object Capture / PhotogrammetrySession** for photogrammetric
detail; **RoomPlan** (iOS 26 adds colours, measurements and room area to the
model and the export). Metal 4 + MetalFX for GPU work.

**Where we are:** the app already uses all three (ARKit LiDAR fusion is the core
pipeline — see [02-scan-pipeline](02-scan-pipeline.md); `GuidedObjectCapture` and
`RoomPlanScan` exist). The custom marching-cubes + photo-bake pipeline is
genuinely sophisticated (ICP, Manhattan-world lock, shape snapping, atlas
paging).

**Recommendations:**
- Confirm RoomPlan uses the iOS 26 model improvements (colours/measurements/area)
  in its export — cheap win if not.
- The known geometry/texture quality floors (±~16 mm pre-ICP jitter, atlas
  area-ceiling texture blur) are already mapped in memory; the **multi-page atlas**
  (built, not activated) is the highest-value pipeline unlock. See
  [02-scan-pipeline](02-scan-pipeline.md).
- Consider offering **Object Capture (photogrammetry)** as a quality path for
  small objects where LiDAR resolution is the limit — the framework is already
  linked.

## 4. On-device intelligence — 🔴 untapped, high differentiation

**State of the art (iOS 26):** the **Foundation Models framework** exposes
Apple's on-device LLM (guided generation with `@Generable`, tool calling,
streaming) — free, private, offline. Plus the Vision framework (classification,
saliency) and Visual Look Up.

**Where we are:** none of this is used. Scans are named by timestamp/bounding-box.

**Recommendations (genuine "top-tier" differentiators, all on-device / private):**
- **Auto-name & auto-describe scans** — feed the mesh classification + dimensions
  to the on-device model to produce "Oak dining chair, 92 cm" instead of
  "Object 33×29 cm". Small, delightful, private.
- **Natural-language gallery search** — "show my chairs" / "rooms bigger than
  20 m²" via the on-device model over scan metadata.
- **Vision object classification** during capture to label what is being scanned.

These fit the app's privacy story (all on-device) and are strong marketing.

## 5. Concurrency — 🟡 Swift 6.0 → 6.2 "approachable concurrency"

**State of the art:** Swift 6.2 with `-default-isolation MainActor`, `@concurrent`
for explicit offload, and isolated conformances — less boilerplate, fewer false
data-race errors, clearer offload intent.

**Where we are:** Swift 6.0 strict concurrency (`SWIFT_VERSION 6.0`), already
correct (see [01-architecture](01-architecture.md)). Adopting 6.2's default main
isolation would simplify the many `@MainActor`/`nonisolated` annotations and make
the detached-offload points (`Task.detached` for bakes/exports) read as
`@concurrent`. Low urgency, good hygiene.

## 6. Live Activities / Dynamic Island — 🔴 absent (user-reported)

**State of the art:** ActivityKit Live Activities render on the Lock Screen and
in the Dynamic Island; ideal for a long-running, glanceable task.

**Where we are:** none — no `ActivityKit`, no `NSSupportsLiveActivities`. This is
exactly why "nothing shows in the Dynamic Island". A **scan-progress Live
Activity** (point count / coverage / elapsed, with a stop affordance) is a
natural, high-visibility feature and the widget extension to host it already
exists. Full plan in [07-roadmap](07-roadmap.md) and
[04-features-and-integrations](04-features-and-integrations.md).

## 7. Widgets & distribution — 🟡 shipped, can go further

The new home-screen widget is current. Next-tier: **Control Widgets** (a
Control Center / Lock-Screen "Start scan" control, iOS 18+), interactive widgets
via App Intents, and Liquid-Glass accented rendering (`widgetAccentable()`).

---

## Summary — what "top tier today" would add, ranked by ROI

| Rank | Move | Value | Cost | When |
|------|------|-------|------|------|
| 1 | Multi-page texture atlas (pipeline, already built) | High | S | Now/next |
| 2 | Native Liquid Glass on primary chrome (iOS 26 cond.) | High | M | Next |
| 3 | Scan-progress Live Activity + Dynamic Island | High | M | Next (user wants) |
| 4 | On-device auto-naming / NL gallery search (Foundation Models) | High | M | After 1.0 |
| 5 | RoomPlan iOS 26 model improvements in export | Med | S | Next |
| 6 | SceneKit → RealityKit migration | High | XL | Dedicated epic, post-1.0 |
| 7 | Swift 6.2 approachable concurrency | Low | M | Opportunistic |
| 8 | Control Widget "Start scan" | Med | S | After 1.0 |

## Sources
- [Bring your SceneKit project to RealityKit — WWDC25](https://developer.apple.com/videos/play/wwdc2025/288/)
- [SceneKit deprecation & RealityKit migration guide (DEV)](https://dev.to/arshtechpro/wwdc-2025-scenekit-deprecation-and-realitykit-migration-a-comprehensive-guide-for-ios-developers-o26)
- [Liquid Glass design system (internal skill reference, iOS 26 APIs)]
- [Live Activities iOS 26 guide (Swift Crafted)](https://swiftcrafted.dev/article/live-activities-dynamic-island-ios-26-swiftui-activitykit-guide)
- [RoomPlan (Apple Developer)](https://developer.apple.com/augmented-reality/roomplan)
- [Apple Foundation Models framework (on-device LLM, iOS 26)](https://developer.apple.com/documentation/foundationmodels)
