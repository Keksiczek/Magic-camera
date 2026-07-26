# 08 · Product Coherence & Feature Ideas

_Written 2026-07-26. A step back from the code: are the modes logically coherent,
and what is worth adding or extending? Companion to [03-ux-and-design](03-ux-and-design.md)
(detailed UX findings) and [07-roadmap](07-roadmap.md) (the backlog). This doc is
the "does it all hang together, and where next" view._

---

## 1. The mode map (what the app actually is)

Home screen surfaces, and what each really does:

| Surface | Tech underneath | Output | Best for |
|---|---|---|---|
| **Spatial Scan** (hero) | LiDAR depth → point cloud → reconstructed textured mesh | `.mcmesh` + USDZ/GLB/PLY/web | Rooms and medium objects, fast, "good enough" fidelity |
| **Object Capture** | Photogrammetry (`PhotogrammetrySession`, photos) | USDZ | Small, detailed objects where LiDAR is too coarse |
| **Room Plan** | ARKit `RoomPlan` (parametric) | Parametric room (walls/doors/windows/furniture) | A CAD-like floor plan, not a mesh |
| **Model Studio** | Manual + chat-driven mesh editing (primitives, CSG, transforms) | `.mcstage` / edited mesh | Building / cleaning / combining models after capture |
| **Live Depth** | Real-time LiDAR depth render | (creative, no persistent 3D) | A live depth-camera toy / effect |
| **Scan Gallery** | Library of saved scans | — | Browse, reopen, share, hand off |

Plus the cross-cutting layer: iCloud sync, the home-screen widget, the scan
Live Activity, App Intents / Shortcuts, AR Quick Look.

---

## 2. Is it coherent? — findings

### 2.1 ✅ What holds together well
- **The Room/Object unification inside Spatial Scan** (removing the old Point vs
  Mesh mode) is a genuine simplification — one capture flow, the tech hidden.
- **Capture → review → edit → export** is a clean, linear spine. Export is
  consistent (gallery and review both export the same formats).
- **Model Studio as a post-capture hub** is a sensible "second stop" for anything
  that needs cleanup or composition.
- **The "nothing leaves your device" story** is real and consistent (local +
  the user's own iCloud, no accounts, no analytics) — a strong, honest position.

### 2.2 ⚠️ The main incoherence: three overlapping capture entry points
The home screen presents **Spatial Scan** as "Scan anything — objects, rooms,
areas", and then *also* offers **Object Capture** and **Room Plan** as separate
peer tiles. From the user's side that reads as three doors to the same room:
- Spatial Scan says it scans objects **and** rooms.
- Object Capture also scans objects.
- Room Plan also scans rooms.

The real difference is **technological, not intentional** (LiDAR mesh vs
photogrammetry vs parametric CAD), but nothing on the home screen tells the user
*when* to pick which. A newcomer cannot answer "I want to scan this vase — which
tile?" This is the single biggest coherence gap, and it's what
[07-roadmap 2.5](07-roadmap.md) gestures at ("clarify home mode taxonomy").

### 2.3 ⚠️ Two places to edit geometry
Spatial Scan's review has its own edit tools (isolate, smooth, fill, snap,
measure…) and **Model Studio** is a separate editor. The boundary is real
(review = fix this one scan; Studio = compose/build across models) but it isn't
signposted, so "where do I go to clean this up?" is ambiguous.

### 2.4 ⚠️ Live Depth is an orphan
It's a live depth-camera effect with no path into the 3D pipeline — it neither
produces a scan nor feeds the gallery. Fine as a toy, but it sits on the home
screen with the same visual weight as the core capture modes, inflating the
"which of these six things do I want?" load.

---

## 3. Recommendations to make it cohere (no big rewrites)

1. **Regroup the home screen by INTENT, not by technology.** e.g.
   - *Scan a space* → Spatial Scan (room) / Room Plan as an "exact floor plan" option.
   - *Capture an object* → Spatial Scan (object) for quick, Object Capture for
     high-fidelity — offered as "Fast (LiDAR)" vs "Detailed (photos)".
   - *Create & edit* → Model Studio.
   - *Play* → Live Depth (visually de-emphasised / in a secondary row).
   A one-line "best for…" under each removes the guesswork. **S–M**, pure UX.
2. **Add a "not sure? " smart picker** — one question ("What are you scanning?
   a room / a small object / a big object") that routes to the right tech. Pairs
   naturally with first-run onboarding ([07-roadmap 2.4](07-roadmap.md)). **M**.
3. **Cross-link the two editors.** From Spatial Scan review, a clear "Open in
   Model Studio" (already exists as "Send to Studio") — and, conversely, name the
   review tools "Quick fixes" so the split reads as quick-vs-full. **XS**.
4. **Bridge the capture techs** where one is weak: when a Spatial Scan Object
   subject is small/failing, offer "Recapture in Object Capture for more detail"
   ([07-roadmap 4.2](07-roadmap.md)); overlay a Room Plan onto its Spatial Scan
   mesh. **M**.

---

## 4. Feature ideas to add / extend (prioritised, on-brand)

Anchored to the "everything stays on your device" positioning — the ideas that
lean into it are the differentiators.

### High value, feasible soon
- **On-device AI (FoundationModels, iOS 26).** Auto-name and one-line-describe a
  scan from its geometry/photos; natural-language gallery search ("the kitchen
  scan with the round table"); live Vision object labels during capture. Entirely
  on-device → a headline feature that reinforces the privacy story.
  ([07-roadmap 4.1](07-roadmap.md)) **M.**
- **Measurement upgrades.** The 3D ruler is point-to-point today; add a polyline /
  perimeter, area and volume, and — from a Room Plan — labelled wall dimensions.
  A practical, "why I'd actually use this" feature. **M.**
- **Export presets with size hints.** "AR-ready USDZ", "game-ready (decimated)",
  "archival (full-res)", "point data (PLY)", each with an estimated file size —
  instead of a flat format list. ([07-roadmap 2.6](07-roadmap.md)) **M.**
- **Per-scan widget deep link + Control Widget.** `magiccamera://scan/<id>` to
  open a specific scan (the widget currently only links to the gallery), and an
  iOS Control Center "Start scan" control. ([07-roadmap 2.3, 4.4](07-roadmap.md)) **S.**

### Medium — depth and polish
- **Interactive Live Activity** — a "Finish scan" button on the lock screen /
  Dynamic Island (now that the Live Activity ships).
- **Library management** — tags / albums, favourites (partly there), bulk export,
  and search (pairs with the AI naming above).
- **Scan completion score** — turn the existing coverage/heatmap telemetry into a
  single "this scan is 85% covered — sweep the far wall" prompt at finish.
- **Turntable / orbit video export** already exists — extend to a shareable
  branded clip for social ("made with Magic Camera").

### Larger / strategic (after 1.0)
- **CloudKit `CKShare` collaboration** — share an *editable* scan with another
  user (deferred; the sync plumbing is already CloudKit-adjacent).
- **RealityKit migration** — SceneKit is soft-deprecated; a dedicated epic, not
  urgent while it works ([07-roadmap 4.5](07-roadmap.md)).
- **Object Capture on-device pipeline polish** — make photogrammetry a
  first-class, guided flow rather than a separate tile.

---

## 5. One-paragraph verdict

The pipeline (capture → reconstruct → review → export) is coherent and the
privacy positioning is a real asset. The one thing that genuinely confuses is the
**home-screen mode taxonomy**: Spatial Scan, Object Capture and Room Plan are
presented as peers when they're really "the same intent, different engine."
Fixing that (group by intent + a smart picker + "best for" lines) is the highest-
leverage coherence work and it's pure UX — no pipeline risk. After that, the
on-device-AI and measurement features are what turn a solid scanner into a
distinctive one.
