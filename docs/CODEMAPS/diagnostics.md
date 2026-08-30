# diagnostics — how a breadcrumb reaches an export

The diagnostics export is **the only channel that survives a watchdog kill**,
and every round from r74 on was debugged from it. It is a first-class feature,
not developer leftovers.

**Ship the breadcrumb with the fix.** A change that cannot be seen in an export
is a change that cannot be verified.

## The mechanics

`Diagnostics.shared` (`MagicCamera/Core/Diagnostics.swift`) is a
`@unchecked Sendable` singleton with a serial IO queue, so appends never race.

```
Diagnostics.shared.log("kind — field N, field M")     ← rolling breadcrumb line
Diagnostics.shared.gpu("kind …")                      ← GPU-path breadcrumb
Diagnostics.shared.memory("label start|end")          ← memory snapshot around a stage
MetricKit payloads (crash / CPU exception / hang / disk write)  ← captured in the field
        │
        ▼
Application Support/Diagnostics/{breadcrumbs.log, payloads/}
        │  breadcrumbs trimmed at 256 KB (tail kept), ≤40 diagnostic payloads, ≤8 metric payloads
        ▼
Settings ▸ Diagnostics ▸ exportArchive()  →  one shareable .txt
```

**The breadcrumb file is a ring and spans sessions.** Check the timestamp on
anything surprising before drawing a conclusion from it. A `begin` with no
matching `end` is a heavy operation that never finished — that is the signature
of a watchdog kill, not a missing log.

## The kinds the code emits

`make verify-docs` fails if the code emits a kind this list does not name.

**Capture**
`scan start` · `scan config` · `scan` · `scan chunk` · `scan quality` ·
`scan icp` · `scan finished` · `scan metrics` · `sample grading` · `lattice` ·
`support check` · `keyframes` · `keyframe select` · `walk` · `after capture`

**Reconstruction and cleanup**
`recipe` · `prep funnel` · `isolate funnel` · `bilateral denoise` ·
`radius-outliers` · `visibility trim` · `component trim` · `ghost trim` ·
`surface cleanup` · `surface holes` · `solid fill` · `shape snap` ·
`cloud snap` · `object model` · `object reconstruct`

**Texture**
`texture-bake` · `bake budget` · `bake timing` · `uv gate` · `multi-view skip`

**Session, storage, system**
`autosave` · `autosave FAILED` · `studio autosave` · `memory pressure` ·
`iCloud` · `photogrammetry`

## The shape fields (added after r88)

Counts alone could not answer three questions that each cost a round to settle
by hand off the user's scan files. `ScanShapeReport` puts all three on
breadcrumbs that already existed:

| Field | On | Reads |
|---|---|---|
| `bbox A×B×C · thin R` | every `isolate funnel` line, and `scan finished — mesh` | **the pancake test.** `thin` is shortest extent ÷ longest; under ~0.15 is what `isFlat` refuses. The r88 lamp was `108×125×1 mm · thin 0.008` and nothing in the export said so |
| `y lo→hi m · a/b/c/…%` | `prep funnel`, `scan finished — points`, `scan finished — mesh` | **where the points are, by height band.** Compare the cloud's profile with the mesh's: a band that empties between them is the furniture a stage deleted, and it names the band |
| `thermal nominal\|fair\|serious\|critical` | `scan config`, `scan finished — points` | ARKit sheds depth frames under thermal pressure well before the user feels heat |

## Reading an export

Order matters — read it this way, not by scrolling:

1. **`scan config`** — which knobs this scan actually ran with. Every later
   number is meaningless without it.
2. **`scan quality — raw A → kept B`** — what the filters took. **A filter
   taking more than a third of the cloud is the finding**, not a detail. The
   r88 room lost 1,599,919 of 3,215,986 points to one hardcoded 0.65 bar.
3. **`scan icp — … tilt N°`** — must stay `0.00`. `drag` is the runaway guard.
4. **`scan quality — … snapped N`** — must be `0` on any scan that stays under
   60% of its cap. A non-zero value on a scan under pressure is correct
   behaviour, not a bug.
5. **`surface cleanup — planes N`** — must be `0` on an **Object** scan. A
   subject that got planes was flattened.
6. **`texture-bake — … repaired N/M`** against **`bake budget — … pages ≤ P`** —
   repaired texels are texture that was *synthesised*, not photographed.
7. **`memory pressure`** events and the peak.

## What the export cannot answer yet

Add to this list freely. **An entry costs a line; rediscovering it costs a
round.** Removing one means the field shipped.

* **Which *individual prep stage* emptied a band.** The height profile is
  logged for the funnel's input and for the delivered mesh, so the loss is
  bracketed between the two — but a nine-stage prep still needs bisecting by
  hand. Per-stage profiles would close it; they cost nine passes, so measure
  whether the bracket is enough first.
* **Why a stage stopped early.** Where a stage bails, the crumb says it
  stopped, not what tripped it.
* **Chart shatter.** `texture-bake` reports charts and repaired texels, not the
  chart *size* distribution — the r88 room's 44,248 charts at a 12 px median is
  the next lever after the triangle budget, and it is not in the export.
* **Per-keyframe rejection reasons.** `keyframe select` reports the count kept,
  not why the others lost.

## The trap

**A field the export builder does not name is invisible, and the code that
emits it looks correct.** When adding a key to a breadcrumb, check both ends in
the same commit: the emission *and* the line that renders it into the archive.
This has been the same defect several times over in sibling projects, and it is
prose-only here — if you touch it, consider whether the fix is a test.
