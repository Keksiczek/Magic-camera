# Magic Camera — App Analysis (pre-App-Store)

_Generated 2026-07-24 · branch `claude/cloud-mesh-postprocess-optimize-8cb455` @
`e20dbfb` · ~36,400 LOC Swift, iOS 17+ target, Xcode 26 / iOS 26 SDK._

A full-surface audit produced to plan the **final rounds before the App Store**
(the app may be renamed). It combines a deep read of every subsystem (four parallel
analysis passes) with research into what is state-of-the-art on Apple platforms
today (iOS 26). Use it as the working reference across the coming rounds — it is
versioned with the code so any future session can pick it up.

## Executive summary

**Magic Camera is a genuinely strong, unusually mature LiDAR 3D-scanning app** —
research-grade reconstruction, a broad and polished feature set, a real design
system, and best-in-class field diagnostics. It is much closer to shippable than a
typical pre-1.0 project. The work that remains is **narrow and well-defined**, not a
rebuild.

What's excellent:
- **Scan pipeline** — frame-to-model ICP, TSDF fusion with ray-carving, Hoppe
  signed-field reconstruction, searched-gate UV unwrap; GPU paths with CPU fallbacks
  and a CPU correctness gate. ([02](02-scan-pipeline.md))
- **Architecture & concurrency** — a disciplined Swift-6 model, a real
  operation-runner (exclusive slot + stale-guard + cancel + background assertion),
  robust versioned binary codecs, deep watchdog defense, exceptional hygiene
  (0 `print`/`try!`/`fatalError`). ([01](01-architecture.md))
- **Features** — Model Studio (on-device-AI tool-calling model editor), Live Depth
  (pro depth-effects + RGBD/measure/Vision), RoomPlan (multi-room + hybrid points +
  texture), and a comprehensive export suite are all at/near best-in-class.
  ([04](04-features-and-integrations.md))
- **UX** — opinionated "camera-dark glass" identity, pervasive graded haptics, a
  grace-delayed cancellable processing overlay, strong empty/loading/error states.
  ([03](03-ux-and-design.md))

The gaps that matter:
- **Ship blockers** are few: a missing **privacy manifest**, an **untested Object
  Capture** module (never compiled in-sim), **no runtime memory-pressure handling**
  (jetsam risk), and this branch's scan/bake not yet **device-verified**. ([06](06-appstore-readiness.md), [01](01-architecture.md))
- **The Dynamic Island shows nothing because there is no Live Activity** — the
  home-screen widget that was added is a different thing (WidgetKit vs ActivityKit).
  A scan-progress Live Activity is the highest-visibility feature to add, and the
  host + progress hook already exist. ([04](04-features-and-integrations.md))
- **Biggest quality lever:** the **multi-page texture atlas** is fully built but
  dormant — activating it roughly halves texture blur on large rooms. ([02](02-scan-pipeline.md))
- **Currency:** SceneKit (the app's render/export backbone) is **soft-deprecated**
  since iOS 26 — RealityKit is the future, but this is a strategic epic, not urgent.
  The custom `glassPanel` predates native **Liquid Glass**. ([05](05-tech-currency.md))

## Subsystem scorecard

| Area | State | Headline gap |
|------|-------|--------------|
| Scan pipeline | 🟢 excellent | texture atlas dormant; god-object files |
| Architecture / concurrency | 🟢 strong | no memory-pressure governor; VM too large |
| Model Studio | 🟢 flagship | no redo; fixed CSG resolution |
| Live Depth | 🟢 broad | no golden tests for RGBD |
| RoomPlan | 🟢 complete | device-only; polling vs RoomPlan pipeline |
| Object Capture | 🟡 unverified | never compiled — **must device-test** |
| iCloud / Widget / Sharing | 🟡 shipped | widget-delete staleness bug; no per-scan link |
| UX / GUI | 🟢 premium | Dynamic Type; a few VoiceOver labels; onboarding |
| Live Activity / Dynamic Island | 🔴 absent | build it (user's ask) |
| App Store readiness | 🟡 near | privacy manifest; name/version/screenshots |
| Tech currency | 🟡 | SceneKit soft-deprecated; native Liquid Glass |

🟢 strong · 🟡 needs work · 🔴 missing

## Top 10 priorities (punch list)

1. **Privacy manifest** (`PrivacyInfo.xcprivacy`) — ship blocker. ([06](06-appstore-readiness.md))
2. **Device-verify Object Capture** + this branch's scan/bake. ([04](04-features-and-integrations.md), [01](01-architecture.md))
3. **Memory-pressure governor** — closes the biggest crash risk. ([01](01-architecture.md))
4. **Scan-progress Live Activity / Dynamic Island** — user's ask. ([04](04-features-and-integrations.md))
5. **Activate the multi-page atlas** (+ JPEG export) — biggest quality jump. ([02](02-scan-pipeline.md))
6. **Discard confirmation** for unsaved scans. ([03](03-ux-and-design.md))
7. **Dynamic Type + missing VoiceOver labels.** ([03](03-ux-and-design.md))
8. **Fix widget staleness on delete** (regression). ([04](04-features-and-integrations.md))
9. **Native Liquid Glass** on primary chrome (iOS 26, conditional). ([05](05-tech-currency.md))
10. **Name, version 1.0.0, screenshots, App Store Connect record.** ([06](06-appstore-readiness.md))

Full sequenced plan (Tiers 0–4, with effort): **[07-roadmap](07-roadmap.md)**.

## Documents

| File | Contents |
|------|----------|
| [01-architecture.md](01-architecture.md) | App structure, Swift-6 concurrency, stores, GPU, cloud, tech debt |
| [02-scan-pipeline.md](02-scan-pipeline.md) | Capture → reconstruct → texture → export; quality ceilings |
| [03-ux-and-design.md](03-ux-and-design.md) | Flows, design system, interaction polish, accessibility |
| [04-features-and-integrations.md](04-features-and-integrations.md) | Studio, RoomPlan, Object Capture, Live Depth, AR, iCloud, widget, exports, Live Activity |
| [05-tech-currency.md](05-tech-currency.md) | Benchmark vs. today's iOS 26 tech; what "top-tier" would add |
| [06-appstore-readiness.md](06-appstore-readiness.md) | Submission checklist, privacy manifest, blockers |
| [07-roadmap.md](07-roadmap.md) | Prioritized, sequenced plan for the final rounds |

## Open product decisions

- **Final app name** (rename likely) — lock it *before* creating the App Store
  Connect record; it propagates into the iCloud container, App Group, and URL-scheme
  identifiers (all currently embed `com.keks.MagicCamera`).
- **Deployment target** — staying iOS 17 keeps reach but gates native Liquid Glass /
  some iOS 26 APIs behind `#available`; a future iOS-26-only pivot is a separate call.

## Notes

- Persistent project memory (cross-session context, the r10–r64 scan history, the
  paid-program integration record) lives in the Claude project memory at
  `~/.claude/projects/-Users-keks-Developer-Magic-camera/memory/`. This `docs/analysis/`
  set is the versioned, in-repo companion.
- Findings cite `file:line` against this worktree so they stay actionable as the code
  evolves — re-verify a citation before acting if the file has since changed.
