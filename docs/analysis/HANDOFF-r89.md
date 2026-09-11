# r89 — the repository round: `main` is the trunk again

**This was not the device round.** [DEVICE-ROUND-r89.md](DEVICE-ROUND-r89.md) is
unchanged and still the script to run on the phone; its A1 — *the whole branch is
device-unverified* — is still true, and now for a second reason: **this host can
no longer compile the app at all.** Written 2026-09-10 against `1b3a132`.

What this round did was stop the repository from lying about where the work is.

---

## 1. What was measured

`main` looked healthy — `git status` clean against `origin/main`, no divergence —
and was two months of work behind:

| Measurement | Value |
|---|---|
| `main` before | `2d5c7a4` = `c096dac` **plus an empty merge commit** |
| why empty | PR #21 merged `claude/eloquent-euclid-2d4bd4`, whose tip **is** `c096dac`, so `main`'s own commit carried no tree change |
| commits only on `claude/cloud-mesh-postprocess-optimize-8cb455` | **67** (tip `bfb8a86`, 2026-08-30) |
| that diff | 133 files, +16,728 / −3,814 |
| `cs.lproj` on `main` | **absent** — the Czech localisation was branch-only |
| `make verify-docs` on `main` | `make: *** No rule to make target 'verify-docs'` |
| branch vs `origin` | **37 commits unpushed**, since `9374616` (HANDOFF-r74) |

So everything from the scan-quality series onward lived on one unpushed branch:
graded sample confidence, multi-object isolation, the ICP lever-arm and levelling
fixes, the area-driven reconstruction lattice, the multi-page atlas and its
budget, ScanMetrics, the memory-pressure governor, iCloud backup, scan sharing,
the widget, the Czech localisation, and the enforced documentation system itself.

**The dangerous part was the working tree.** `main` carried 31 documentation
paths staged-but-uncommitted — `CLAUDE.md`, `docs/CODEMAPS/`, `docs/FMEA.md`,
`docs/analysis/` — byte-identical to the branch's copies
(`git diff --name-status <branch> -- CLAUDE.md docs/` was empty). New
documentation describing code that was not there: `docs/CODEMAPS/policy.md` cited
rules whose tests `Tests/` did not contain, and the script that would have caught
it was itself one of the missing files.

## 2. What was done

| | |
|---|---|
| merge | `1b3a132`, `--no-ff`. Tree afterwards is **identical** to `bfb8a86` (`git diff main <branch>` empty) |
| the staged docs | discarded before the merge, not committed twice — they came back from the branch unchanged |
| pushed | `origin/main` `2d5c7a4..1b3a132`; `origin/…-8cb455` `9374616..bfb8a86`. Both refs now 0/0 against local |
| backup refs | tags `backup/pre-merge-main`, `backup/pre-merge-branch` |
| `make verify-docs` | passes on the merged tree |
| `xcodegen` | 2.45.4 present; regenerating produces **no diff** against the committed `MagicCamera.xcodeproj` |

**406 MB of device evidence was one command from being deleted.** Nineteen
untracked files — six diagnostics exports, eight textured USDZ scans, five
screenshots, all from the r71–r74 rounds in July — were sitting inside the
`eloquent-euclid-2d4bd4` worktree, which is fully merged and therefore a
`git worktree remove` candidate. They are now in `evidence/2026-07-r71-r74/`,
and `evidence/` is gitignored: too big to commit, too dear to lose, because §3
says the artefact is the only channel.

Four claims that were true when written and had become false were corrected —
each one had already cost this round time:

* `CLAUDE.md` §1 — *"`main` has been 65 commits behind"*, and the simulator rule.
* `docs/FMEA.md` §A — the destination row, plus a new row for the `actool` failure.
* `docs/analysis/README.md` — header branch, commit and code counts.
* `Makefile` — the `SIM` comment, and `check` now runs `build-device`.

## 3. The finding that will cost the next session a round

**No iOS simulator runtime is installed, and without one nothing builds — not
even for a device.**

```
$ xcrun simctl list runtimes
== Runtimes ==                                    # empty

$ xcrun simctl list devices
-- Unavailable: com.apple.CoreSimulator.SimRuntime.iOS-26-3 --
    iPhone 17 (…) (Shutdown) (unavailable, runtime profile not found …)

$ make build
xcodebuild: error: Unable to find a device matching the provided destination specifier:
		{ platform:iOS Simulator, OS:latest, name:iPhone 17 }

$ make build-device
…/MagicCamera/Resources/Assets.xcassets: error: No available simulator runtimes
for platform iphonesimulator. SimServiceContext supportedRuntimes=[]
** BUILD FAILED **
```

Xcode here is **26.2**; the `iPhone 17` device was created against **iOS 26.3**,
which is gone. The second failure is the one worth remembering: a *device*
destination still fails, because `actool` wants a simulator runtime to compile
the asset catalogue, and it blames `Assets.xcassets` — which is not the problem.

The fix is `xcodebuild -downloadPlatform iOS`. It was **not** run this round:
the volume has **11.0 GB free at 90% full** and the runtime wants roughly ten.
Freeing space is the owner's call — `~/Library/Developer/Xcode/DerivedData` is
1.5 GB, and `evidence/` is 406 MB that should be archived rather than deleted.

Until then `make verify-docs` is the only mechanical check that runs here.

## 4. Still unverified, and deliberately left open

* **Nothing was compiled this round.** The merge is content-identical to
  `bfb8a86`, which was itself built but never device-verified; no build has been
  reproduced on this host since the runtime disappeared.
* **The suite has not run since r88** and cannot run here now. Present inventory:
  433 test cases in 67 classes; 52,507 lines of Swift across 233 files.
* **The worktrees are gone.** `eloquent-euclid-2d4bd4`, `epic-euclid-34a00e` and
  `cloud-mesh-postprocess-optimize-8cb455` were all fully merged into `main` and
  held nothing but a stale generated `pbxproj`; all three were removed and
  `git worktree list` is now one line. The hazard they carried was not
  theoretical — **the shell's cwd flapped into `eloquent-euclid-2d4bd4` during
  this very round**, which is exactly the §1 failure, and their untracked
  contents were the 406 MB of evidence above. The `git -C <abs>` rule still
  stands for the next time a worktree exists; the lesson that survives is
  **list a worktree's untracked files before removing it**.
* **The Czech toast gap (D1) is untouched** — 107 of 109 `showToast` literals
  still have no Czech key, and 30 more call sites are not literals at all.
