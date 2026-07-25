> **⚠️ Status is stale as of 2026-07-25 — see [HANDOFF.md](HANDOFF.md) for the
> current source of truth.** Several Tier-0 items (privacy manifest, export
> compliance, v1.0.0, discard guard, widget-on-delete) and Tier-1.1 (multi-page
> atlas) have since SHIPPED. The prioritization below still holds; the ❌/⏳
> markers do not.

# 07 · Roadmap — Prioritized Plan for the Final Rounds

_Synthesis across [01](01-architecture.md)–[06](06-appstore-readiness.md). This is
the working backlog for the pre-App-Store rounds. Each item: priority, effort
(XS/S/M/L/XL), and where it's detailed._

Effort is rough engineering size, not calendar time. "Blocker" = must land before
submission. Do the tiers roughly in order; items within a tier are independent unless noted.

---

## Tier 0 — Ship blockers (do first)

| # | Item | Effort | Detail |
|---|------|--------|--------|
| 0.1 | **Privacy manifest** `PrivacyInfo.xcprivacy` (app + widget) — file-timestamp `C617.1` + UserDefaults `CA92.1` | S | [06 §2](06-appstore-readiness.md) |
| 0.2 | **Device-verify Object Capture** — never compiled in-sim; crash-on-entry risk | S (a device run) | [04](04-features-and-integrations.md) |
| 0.3 | **Device-verify this branch's scan/bake** — keyframe-batching / slice-3072² / 96-keyframes are not device-verified (per memory) | S (a device run) | [01 P0.2](01-architecture.md) |
| 0.4 | **Memory-pressure governor** — no `DispatchSource` memory source / `didReceiveMemoryWarning`; open-loop OOM = jetsam risk | M | [01 P0.1](01-architecture.md) |
| 0.5 | **Discard confirmation** — review "New" destroys an unsaved scan with no confirm | XS | [03 HIGH-1](03-ux-and-design.md) |
| 0.6 | `ITSAppUsesNonExemptEncryption=false`; version → 1.0.0; lock final name + bundle id | XS | [06 §3,5,6](06-appstore-readiness.md) |

## Tier 1 — Top-tier quality wins (the "make it best-in-class" work)

| # | Item | Effort | Detail |
|---|------|--------|--------|
| 1.1 | **Multi-page texture atlas** (built, dormant) — 142 m² room 1.8→~0.9 mm/texel; land `pageCount=1` plumbing then `maxPages:4`; add **JPEG atlas** export | S–M | [02 P0](02-scan-pipeline.md), [05 #1](05-tech-currency.md) |
| 1.2 | **Scan-progress Live Activity / Dynamic Island** — the user's explicit ask; host + progress hook already exist | M | [04](04-features-and-integrations.md), [05 #3](05-tech-currency.md) |
| 1.3 | **Dynamic Type hardening** on the custom camera surfaces (+ AX clamp) | M | [03 HIGH-2](03-ux-and-design.md) |
| 1.4 | **Missing VoiceOver labels** (undo/redo, auto-orbit, measure, Studio steppers) | S | [03 HIGH-3](03-ux-and-design.md) |
| 1.5 | **Native iOS 26 Liquid Glass** on primary chrome, behind `#available(iOS 26)`, `glassPanel` fallback | M | [05 #2](05-tech-currency.md), [03 §2](03-ux-and-design.md) |

## Tier 2 — Feature completeness & polish

| # | Item | Effort | Detail |
|---|------|--------|--------|
| 2.1 | **🐛 Widget staleness on delete** — `ScanGalleryView.delete` must `reload()`/publish (regression in the iCloud/widget commit) | XS | [04](04-features-and-integrations.md) |
| 2.2 | **3 more App Intents** (Object Capture, Room Plan, Model Studio) | S | [04](04-features-and-integrations.md) |
| 2.3 | **Per-scan widget deep link** `magiccamera://scan/<id>` (already advertised by `RecentScan.id`) | S | [04](04-features-and-integrations.md) |
| 2.4 | **First-run onboarding + permission priming** | M | [03 MEDIUM-4](03-ux-and-design.md) |
| 2.5 | **Clarify home mode taxonomy** + remove duplicated title | S | [03 MEDIUM-5](03-ux-and-design.md) |
| 2.6 | **Redesigned export sheet** (3D model / point data / share link, with size hints) | M | [03 MEDIUM-6](03-ux-and-design.md) |
| 2.7 | Web-viewer CDN fallback fail-loud; CloudStore test (or fix the false "unit-tested" comment) + surface partial-migration failures | S | [04](04-features-and-integrations.md) |
| 2.8 | Studio: **redo** + CSG resolution tier; RGBD golden-file tests | M | [04](04-features-and-integrations.md) |

## Tier 3 — Architecture hardening (do alongside features, not as a big-bang)

| # | Item | Effort | Detail |
|---|------|--------|--------|
| 3.1 | **Unify the operation runner** — shared `OperationRunner`; adopt in Studio (gains stale-guard + cancel) | M | [01 P1.3](01-architecture.md) |
| 3.2 | **Decompose `SpatialScanViewModel`** — Capture / ReviewEditing / Export controllers; move geometry helpers into the engine layer (testable) | L | [01 P1.4](01-architecture.md) |
| 3.3 | **Centralize tuning** into a typed `ScanTuning` namespace (kill scattered magic numbers) | M | [01 P1.5](01-architecture.md) |
| 3.4 | Split the other 800+ LOC files; full `loadUnaligned` in `MeshStore`; shared `MetalContext`; snapshot `ARMeshAnchor` geometry; replace the auto-fix busy-wait | M | [01 P2](01-architecture.md), [02](02-scan-pipeline.md) |
| 3.5 | Introduce DI/protocols over singletons + first VM-level tests (runOperation semantics) | M | [01 P2.8](01-architecture.md) |

## Tier 4 — Differentiators & strategic (after 1.0)

| # | Item | Effort | Detail |
|---|------|--------|--------|
| 4.1 | **On-device AI** (FoundationModels) — auto-name/describe scans, natural-language gallery search; Vision object labels during capture. Fits the "nothing leaves your device" story | M | [05 #4](05-tech-currency.md) |
| 4.2 | **First-class "hand small objects to Object Capture"** flow (photogrammetry where LiDAR is weakest) | M | [02 P3](02-scan-pipeline.md) |
| 4.3 | **Revisit the 28 mm geometry floor** now ICP cut noise ~16→2 mm — flagged, real-export-validated only | M | [02 P2](02-scan-pipeline.md) |
| 4.4 | **Control Widget** "Start scan"; Swift 6.2 approachable concurrency | S / M | [05 #7,#5](05-tech-currency.md) |
| 4.5 | **SceneKit → RealityKit** migration — dedicated epic; SceneKit is soft-deprecated but works, so this is strategic, not urgent | XL | [05 #6](05-tech-currency.md) |

---

## Suggested sequencing for the next rounds

- **Round A (submission-ready):** Tier 0 in full → the app is legally/technically
  submittable. Small, mostly config + two device runs + the memory governor.
- **Round B (wow):** 1.1 multi-page atlas (biggest visible quality jump) + 1.2 Live
  Activity (the user's ask) + 2.1 the widget bug.
- **Round C (premium feel):** 1.3/1.4 accessibility + 1.5 Liquid Glass + 2.4/2.5/2.6
  onboarding/taxonomy/export.
- **Round D+ :** Tier 3 hardening opportunistically, then Tier 4 differentiators.

Do **not** start the SceneKit→RealityKit migration (4.5) until the pipeline, UX and
1.0 are locked — it's a large rewrite of a currently-working layer.

## Cross-cutting reminders (from project memory)

- Validate any atlas/geometry change against **real device exports**, never synthetics
  (this has burned the project 3×).
- Work in the worktree branch the user builds directly; run `xcodegen generate` after
  adding files; the generated `project.pbxproj` is committed, so keep it in sync.
- Batch edits, build once at the end; verify with `xcodebuild build`, not tests.
