# r71 — the first r70 device round, measured

_2026-07-28. Inputs: a device diagnostics export (`…20260728-113741`), the room
and object point clouds (`scan 6.ply`, `scan 7.ply`) and both textured USDZ
exports from the same session. Everything below is **measured off those files**,
not inferred from code — the harnesses are in `scratchpad/` and re-runnable._

The user's summary was "the 3D model is the weak link". That is correct, and it
decomposes into three independent causes, none of which is the reconstruction
algorithm.

---

## 0. What the session actually did

| | Room | Object |
|---|---|---|
| capture | 6 min 41 s, 4 188 092 pts | 3 short scans, best 62 143 pts |
| cloud extent | 6.76 × 2.95 × 7.61 m | 0.30 × 0.18 × 0.48 m |
| nn spacing (p35 / median) | 7.3 / 8.4 mm | 2.2 / 2.4 mm |
| local-plane RMS | **15.3 mm** | **3.7 mm** |
| mesh | 253 062 tris, 42 mm cells | 9 419 tris, 4 mm cells |
| mesh surface area | 158.8 m² | 0.05 m² |
| atlas | 8192², **1 page** | 3133², 1 page |
| **texel density** | **2.63 mm/texel** | 0.14 mm/texel |
| USDZ | 94.5 MB | 7.6 MB |

The capture side is healthy. `sample grading — mean 0.66 · doubtful 6.2%` on the
room and `0.85–0.90 · 1.8–2.9%` on the objects is exactly the r70 target band,
and the 15.3 mm room / 3.7 mm object plane RMS is the known LiDAR noise floor,
unchanged. **r70's graded confidence is not implicated in anything below.**

Everything that went wrong happened *after* capture.

---

## 1. 🔴 The app was killed mid-bake, and the retry made it worse

The single most serious finding, and a ship blocker.

```
09:06:39  ▶ Building textured surface
09:07:11  memory pressure — critical      ← cancelHeavyWork()
09:07:18  memory pressure — critical
09:07:27  ▶ Building textured surface     ← retry #1, 16 s later
09:07:27  memory pressure — critical
09:07:27  memory pressure — critical
09:07:28  ▶ Building textured surface     ← retry #2, 1.6 s later
09:07:48  app launch                      ← the app is gone
09:08:08  ▶ Building textured surface     ← same job, fresh process
09:09:03  ■ ok · 54 921 ms                ← completes comfortably
```

The same bake that died succeeded 40 seconds later in a cold process. So the
bake is not too big for the device — it is too big for a process that has just
finished a 6.7-minute, 4.2 M-point capture.

Three separate defects stack here:

**(a) `cancelHeavyWork()` releases the operation slot before the work stops.**
It calls `endOperation()` immediately so the UI doesn't sit on a dead spinner,
but the detached task only unwinds at its next checkpoint. The button re-enables
while the cancelled bake is still holding the atlas, the slice array and 75
keyframes — so retry #1 started a *second* full bake alongside the first, and
retry #2 a third. That is the jetsam.
→ Fixed: `heavyWorkInFlight` latch, cleared only when the task has really
returned; `beginOperation` refuses until then.

**(b) The cancel does not bite.** Pass 1 of the bake is
`DispatchQueue.concurrentPerform(iterations: 253_062)`, each iteration scoring 75
views — 19 M scorings. GCD workers are not in the Task context, so
`Task.isCancelled` inside the body is always `false` and **every one of those
scorings runs to completion after `task.cancel()`**, holding the memory the
`.critical` handler was trying to free.
→ Fixed: the pass runs in 32 slabs with a cancellation check between them,
bounding the stop at ~3% of the pass for 32 extra dispatch barriers.

**(c) The toast pointed the user back at the wall.** "Low memory — stopped
processing" plus a re-enabled button invites exactly the retry that killed it.
→ Fixed: it now names the recovery that actually worked on device — reopen the
scan, which reruns the job in a fresh process.

**Still open:** why the bake needs that much headroom at all. The atlas (8192²
RGBA = 268 MB) and the slice array (3072²×7 = 264 MB) are live together, on top
of whatever the capture left resident. Shedding capture-side buffers before the
bake starts is the untried lever.

---

## 2. 🔴 The page-budget cap was built on a false premise, and cost the texture 2×

```
bake budget — 253084 tris × 75 kf → pages ≤ 1 (was 4)
```

r67 introduced `bakeCostCeiling = 16 M` in `triangle · keyframe · page` units,
justified as:

> "The multi-page bake re-runs the whole keyframe stream — and every parallel
> per-triangle CPU pass (candidate scoring, texel repair, fallback paint) — once
> PER PAGE"

**That premise was already false when it was written.** `computeViewCandidates`
— the `tris × keyframes` scoring that dominates the CPU bake — sits *above* the
page loop. Verified at r67's own commit `ca170a2` (scoring at line 595, page loop
at 624) and still hoisted today. Paging was being billed for work that happens
identically at one page.

The consequence is not academic. This room scored **253 062 × 75 = 19.0 M against
a 16 M ceiling on the fixed term alone**, so there was never any budget left for
a second page — the cap could not have removed a single unit of that 19 M. The
room fell to one sheet and shipped at a **measured 2.63 mm/texel**, discarding
exactly the multi-page win r65 built.

What genuinely repeats per page: the GPU render, `paintFallbackTriangles`,
`repairUnwrittenTexels`, the seam leveler, `fillGutters`, the atlas encode. All
O(triangles) or O(texels); none carries a keyframe factor.

→ Fixed: the ceiling now bounds **marginal paging work** in `triangle · page`,
calibrated on the three real device timings:

| tris × pages | outcome |
|---|---|
| 62 k × 3 = 186 k | completed, ~50 s |
| 253 k × 1 = 253 k | completed, ~39 s of bake (this round) |
| 205 k × 4 = 820 k | **iOS killed the app mid-bake** (r67) |

500 k sits above both survivors and well under the kill. This room gets 2 pages
(≈1.86 mm/texel, **1.41× sharper**); r67's crashing room gets 2 instead of the 4
that killed it.

→ Also added: a `bake timing` breadcrumb splitting scoring ms from per-page ms.
Two rounds of paging decisions have now been made without ever measuring what a
page costs. The next export replaces the 500 k estimate with device truth.

---

## 3. 🟠 The USDZ ships a 70 MB PNG the app already had as JPEG

`MagicCamera-textured.usdz` is 94.5 MB. Inside: 24 MB of geometry and
`texgen_0.png` at **70 MB**.

The baker encodes the atlas as JPEG q0.92. But `geometry(from:)` decodes it to a
`UIImage` and hands *that* to SceneKit, whose USDZ writer re-encodes into its own
`texgen_N.png`. The JPEG is round-tripped through an uncompressed intermediate
and back out as PNG.

Verified locally on one 2048² sheet — same source atlas, three attachment modes:

| `diffuse.contents` | inside the USDZ | size |
|---|---|---|
| `UIImage` (what the app did) | `texgen_0.png` | **13.0 MB** |
| `CGImage` | `texgen_0.png` | 7.5 MB |
| **file URL** | **`atlas.jpg`** | **5.1 MB** |

A file-URL texture is copied through byte-for-byte. Harness:
`scratchpad/usdzjpeg.swift`.

→ Fixed: `writeUSDZ` spills each page to a temp `.jpg`/`.png` (extension from the
real encoding) and points the material at the file. Fidelity goes **up** — the
export is now the exact bytes the baker produced, with no decode/re-encode — and
the room USDZ should land around 30 MB instead of 94.5 MB. It also skips
decoding an 8192² atlas into a transient bitmap per page.

---

## 4. 🟠 The room meshed at 42 mm, not the 28 mm the noise floor allows

```
lattice — res 161 · cell 42 mm · floor 28 mm
```

The label says `floor 28 mm`; the actual cell is 42 mm — 1.5× coarser linearly,
so ~2.3× fewer triangles than r63/r66 intended (those rounds landed rooms at
28 mm: "small 266k / mid 395k / big 573k"). This room got 253 k for 158.8 m².
Measured mean triangle edge on the export: **38.1 mm**. The cloud supports far
finer — p35 nn spacing is 7.3 mm.

`densityResolution` mins four candidate limits (point spacing, triangle budget,
narrow band, noise floor) and logs only the winner's *value*, never its *name*.
Four different levers, no way to pick. Arithmetic points at the tier triangle
budget, but that depends on which detail tier was active and is not in the log.

→ Fixed (diagnosis only, no behaviour change): `lattice … · bound by budget`.
NEXT-CHAT rule 4 — breadcrumb before tuning blind. **The next export names the
lever; do not move the 28 mm floor or the tier budget until it does.**

---

## 5. 🟡 ICP froze 115 s into a 400 s sweep and nothing said so

```
09:01:53  scan icp — cum bound hit — correction frozen at 300mm
09:06:39  scan icp — applied 3351/4553 · avg 1.9mm · max 9.0mm · cum 200.1mm
```

The summary line reads as textbook health. It hides that the cumulative-bound
guard latched at 115 s and **the remaining ~70% of the room was fused on a stale
correction**.

The guard's ceiling is an absolute 0.30 m (0.10 m for targeted scans). But ARKit
drift accrues with time and distance walked, so a long sweep of a large room
reaches it on entirely ordinary drift — r60 already fixed the *lever-arm* half of
this bug; the absolute-vs-rate half is still there.

→ Fixed (diagnosis only): the finish summary gains `· frozen 70% of sweep`.

**Recommended next, once a second export confirms the pattern:** make the bound a
rate rather than a total — roughly `0.30 m + 0.06 m/min`, capped ~0.60 m, objects
unchanged at 0.10 m. Deliberately *not* done this round: it changes the
registration core, and the guard exists to catch a genuine feedback loop
(the 248 mm pot). One data point is not enough to loosen it.

---

## 6. 🟡 Smaller things, measured

- **`unseen 47930/253062` = 18.9%** of the room's triangles were seen by no
  keyframe and are cloud-painted rather than photographed. Down from the 33% that
  motivated r61's 96-keyframe cap, but still ~1/5 of the room.
- **Object isolation drops 74% of the cloud**: `raw 62143 → kept 16406 → mesh
  9419 tris`, and the mesh bbox (13 × 16 × 22 cm) is much smaller than the cloud
  extent (30 × 18 × 48 cm). That may be correct — `crop-trusted` is meant to
  trust the capture-time crop — but it is worth confirming the user was not
  scanning something bigger than what came out.
- **Both exports are double-sided by construction** (506 124 = 2 × 253 062). That
  is deliberate, for AR Quick Look. Remember to halve before quoting triangle
  counts, and dedupe before any connectivity work.
- **Object texture is excellent** at 0.14 mm/texel. Nothing to do there; the
  object's limit is geometry (4 mm cells against a 3.7 mm noise floor — i.e. it
  is already at the floor).

---

## 7. On the design-resources repo

`bradtraversy/design-resources-for-developers` is a web link list — CSS
frameworks, JS chart libraries, HTML templates, icon fonts. Almost none of it
transfers to a native SwiftUI app, and Tier 1/2 UI work is already done.

The one genuinely useful slice for what's left: **Product & Image Mockups**, for
the App Store screenshots that are still on the user's critical path (6.9"/6.5"
iPhone + iPad). Colour/contrast tools are a distant second for verifying the
Liquid Glass panels hit contrast in both themes.

Not worth a work item beyond that.

---

## 8. Where this leaves the roadmap

Still no *new* ship-blocking feature work — but §1 is a genuine ship blocker that
did not exist as a known issue before this export: **the app can be killed by
its own retry path on a large room.**

Ordered:

1. **Device-verify this round** — §1 (retry is refused, no kill), §2
   (`pages 2 · ~1.86 mm/texel` + the new `bake timing` numbers), §3 (USDZ size
   and that AR Quick Look still shows the texture), §4/§5 (read the new
   breadcrumbs, don't act yet).
2. Then act on §4 and §5 with the breadcrumbs in hand.
3. Then the pre-bake memory shed (§1, still open).
4. User steps unchanged: ASC record, Archive, screenshots, description, privacy
   label.

## 9. Harnesses

In `scratchpad/`, all re-runnable against these exports:

| file | what it measures |
|---|---|
| `measure.swift` | USDZ triangles, area, bbox, UV utilisation, mm/texel |
| `cloudstat.swift` | PLY spacing percentiles + local-plane RMS (the noise floor) |
| `usdzjpeg.swift` | whether `SCNScene.write` keeps a JPEG texture |

⚠️ `SIMD3<Float>` is 16 bytes / 16-byte aligned — never load one straight from a
12-byte-strided ModelIO buffer. That segfault cost time; read component floats.
