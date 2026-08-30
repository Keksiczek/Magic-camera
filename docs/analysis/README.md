# Magic Camera — documentation map

_Last verified 2026-08-10 · branch `claude/cloud-mesh-postprocess-optimize-8cb455`
@ `2b5a528` · 44,515 lines of Swift across 182 files · 429 tests, 0 failures._

This page covers the **analysis** documents only. The maintained core of the
documentation lives one level up and is checked by `make verify-docs`:

| For | Read |
|---|---|
| the operating rules | [`../../CLAUDE.md`](../../CLAUDE.md) |
| a map of the code, by place | [`../CODEMAPS/`](../CODEMAPS/README.md) |
| a symptom you are staring at | [`../FMEA.md`](../FMEA.md) |
| every tested decision rule | [`../CODEMAPS/policy.md`](../CODEMAPS/policy.md) |

Below: three documents here are current and maintained; everything else is a
reference or a dated record, and this page says which is which.

## The three live documents

| Read this | When |
|---|---|
| **[VISION.md](VISION.md)** | Deciding *whether* to build something. What the app is for, what it refuses to be, and the quality ladder that ranks the work. |
| **[07-roadmap.md](07-roadmap.md)** | Deciding *what* to build next. Verified against the code on 2026-08-10, with the evidence for each claim. |
| **[HANDOFF-r88.md](HANDOFF-r88.md)** | Picking up mid-stream. The current round: what was found, how it was measured, what was deliberately left open. |
| **[DEVICE-ROUND-r89.md](DEVICE-ROUND-r89.md)** | Going to the phone. What is open/half-done/broken, the device script to run, and what to send back. |

## Reference — durable, topic by topic

These describe subsystems rather than status. Still useful; treat any status
claim inside them as dated.

| Document | Covers |
|---|---|
| [01-architecture.md](01-architecture.md) | App structure, Swift-6 concurrency, stores, GPU, cloud |
| [02-scan-pipeline.md](02-scan-pipeline.md) | Capture → reconstruct → texture → export |
| [03-ux-and-design.md](03-ux-and-design.md) | Flows, design system, accessibility |
| [04-features-and-integrations.md](04-features-and-integrations.md) | Studio, RoomPlan, Object Capture, Live Depth, iCloud, widget, exports |
| [05-tech-currency.md](05-tech-currency.md) | Where the app sits against current iOS |
| [06-appstore-readiness.md](06-appstore-readiness.md) | Submission checklist |
| [08-coherence-and-ideas.md](08-coherence-and-ideas.md) | Product coherence; referenced from `RootView.swift` |
| [SCAN-TUNING.md](SCAN-TUNING.md) | The tuning constants and what each costs; referenced from `ScanConfig.swift` |
| [APPLE-PIPELINE-NOTES.md](APPLE-PIPELINE-NOTES.md) | What was worth taking from Apple's published pipeline — all four items shipped |
| [UX-AUDIT.md](UX-AUDIT.md) | The by-hand UX pass |

## Dated records — history, not instructions

Round handoffs, kept because the reasoning in them is often the only record of
why a constant has the value it has. **Do not plan from these.**

`HANDOFF.md` · `NEXT-CHAT.md` · `HANDOFF-r74.md` · `HANDOFF-r77.md` ·
`HANDOFF-r86.md` · `r71-device-round.md` · `handoff-multipage-atlas.md`

## The rule that keeps this map true

A status claim belongs in exactly one of the three live documents. Everywhere
else, write what the code *does*, not what is *left to do* — a "still open" line
in a reference document is a line nobody will delete when it closes.

This matters here specifically. The roadmap had carried a "stale since
2026-07-27" banner for weeks while still being planned from; of the ten
priorities on its front page, eight had already shipped. Rewriting it cost a full
audit that the work itself did not need.

## How work gets done here

Measure before theorising. Every fix on this branch that held up started from a
number taken off the user's own scan files or the diagnostics export — a fraction
of points on a lattice, a floor's tilt per quadrant, a repair count against a
page budget. The ones that had to be reverted started from reading the code.
[HANDOFF-r88.md](HANDOFF-r88.md) records the four measurements that work and the
two file-format traps that cost half an hour each.
