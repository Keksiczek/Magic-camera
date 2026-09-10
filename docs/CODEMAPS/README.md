# Codemaps — the map to read before touching anything

Five files, organised by **place**. Each answers one question, each is short
enough to read whole, and none of them duplicates `CLAUDE.md` (the rules),
`../FMEA.md` (symptoms) or `../analysis/` (history and status).

| File | Answers | Open it when |
|---|---|---|
| [architecture.md](architecture.md) | what talks to what, and where a scan goes | anything, first time; you cannot find a caller |
| [scan-pipeline.md](scan-pipeline.md) | capture → reconstruct → texture → export, stage by stage | any change to how a scan becomes a model |
| [policy.md](policy.md) | **every tested decision rule, by name** | you are about to add an `if` to a view model |
| [diagnostics.md](diagnostics.md) | how a breadcrumb reaches an export, and what the export still cannot answer | a crumb, an export line, a device report |
| [surfaces.md](surfaces.md) | the SwiftUI screens and the ones with landmines | any view |

## The contract with the failure register

`../FMEA.md` is organised by **symptom**; these files are organised by **place**.
Every FMEA row carries a `Where` cell naming the file and symbol that owns the
symptom, so the path is: symptom → row → symbol → file.

It runs the other way too. **If you change a rule in one of these files, the
FMEA row that points at it is part of the change.** `make verify-docs` fails
when a `Where` cell stops resolving.

| If you are staring at | FMEA section | Lands in |
|---|---|---|
| a build or toolchain failure | §A | `CLAUDE.md` §1–2 — usually the host or the generator, not the code |
| a scan that came out wrong | §B | `scan-pipeline.md`, `policy.md` |
| memory, watchdog, thermals | §C | `scan-pipeline.md`, `architecture.md` |
| a design decision you are about to make | §D | `policy.md` |
| a document you are about to trust | §E | `../analysis/README.md` |

## Reading order for a cold start

1. `../../CLAUDE.md` — the rules. Short, non-negotiable, paid for.
2. `../FMEA.md` — if something looks broken, this **before** any theory.
3. `../analysis/README.md` → the newest `HANDOFF-rNN.md` — what is going on now.
4. `architecture.md`, then whichever of the other four the task touches.

## What these files are not

Not a record of *state*. Counts, timings and sizes here go stale.
`../analysis/07-roadmap.md` carries what is open; the newest handoff carries
what the last device round proved; the test suite carries the test count.

## Keeping them true

`make verify-docs` fails when a decision rule — `static func` or `static var` —
exists in a policy-bearing file and `policy.md` does not name it in backticks,
when an FMEA `Where` cell does not resolve, when the code emits a breadcrumb
kind `diagnostics.md` does not list (or one whose kind cannot be read at all),
when a document links to a file that is gone, or when one of these files cites a
test class, case or case count that `Tests/` does not have. CI runs the same
script on every pull request. That is why this directory can be trusted.
Everything else here is prose, and prose rots.
