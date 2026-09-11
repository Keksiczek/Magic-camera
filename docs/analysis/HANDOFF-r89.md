# r89 — the repository round: `main` is the trunk again

**This was not the device round.** [DEVICE-ROUND-r89.md](DEVICE-ROUND-r89.md) is
unchanged and still the script to run on the phone; its A1 — *the whole branch is
device-unverified* — is still true, and now for a second reason: **this host can
no longer build the app** (it can still compile it — §5). Written 2026-09-10
against `1b3a132`; §5 added 2026-09-11.

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

Until then `make compile-check` compiles every source with the asset catalogue
excluded — found the next morning, see §5.

## 4. Still unverified, and deliberately left open

* **The merge itself was never compiled here.** It is content-identical to
  `bfb8a86`, built but never device-verified. The tree *after* the §5 cleanup
  was compiled twice by `make compile-check`; nothing has run on hardware.
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

---

## 5. The next morning — a build that runs here, and the dead code it cleared

**`actool` is the only step that needs a simulator runtime.** Excluding the asset
catalogue — `EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets` on the device build — lets
every Swift and Metal source compile on this host as it is. That is now
`make compile-check`, and `make check` runs it. It is safe because the code uses no
generated asset symbols (`Image(.name)`, `ColorResource`); it is a compile check,
not an app — no icon, no accent colour — so its product is never installed. The
first attempt died in a `swift-frontend` segfault in
`fine_grained_dependencies::AbstractSourceFileDepGraphFactory::construct()`; the
retry was clean. That crash was an **arm64 device** build, so the FMEA row calling
these crashes x86_64-simulator-specific was wrong and now says so.

### How the dead code was found — and the trap in it

A reference count per declared symbol, with comments and string literals stripped,
listed 26 functions and 5 types as unreferenced. **Stripping string literals also
strips `\(interpolation)`**, so five of those were live calls inside strings:
`Diagnostics.fileStamp`, `GuidedObjectCapture.remainingText`, both `dateStamp`s and
`WebViewerExporter.runtimeScriptTags`. Fourteen more were protocol requirements
(FoundationModels `Tool.call`, a Quick Look delegate, a gesture delegate) and three
were `@main` / `AppShortcutsProvider` types. **Never delete on the stripped count;
confirm every candidate with a raw `grep -w`.**

### Removed

| Symbol | File | Why it was dead |
|---|---|---|
| `separableComponentCount` | `MeshComponents.swift` | no caller, no test |
| `liveSurface(from:)` | `MeshSceneBuilder.swift` | the Mesh-mode shaded overlay; nothing called it |
| `View.appBackground()`, `GlassButtonStyle` | `UI/Theme.swift` | never applied |
| `scaleModel`, `rotateModel`, `applyModelTransform`, `Operation.transforming` | `+Editing.swift`, `SpatialScanViewModel.swift` | outlived the scan-review chat Studio that called them. `aboutCenter` stays — Model Studio uses it |
| `adaptiveDecimate:` / `baseResolution:` on `SurfaceCleanup.clean` and `ReconstructionPipeline.surfaceCleanup` | `SurfaceCleanup.swift`, `ReconstructionPipeline.swift` | every caller passed `false` |
| `boundedForBake` | `+Lattice.swift` | both callers passed `preservingDetail: false`, which made it `cappedForBake` with a duplicate guard; they call `cappedForBake` now |
| `MeshDecimator.adaptiveDecimate`, `vertexFlatness` | `MeshDecimator.swift` | reachable only through the two dead flags above |
| `ReconstructionSettings.realityKitPreviewEnabled` | `Core/AppSettings.swift` | see the fix below |

About 400 lines. `make verify-docs` and two `make compile-check` runs pass on the result.

### Fixed rather than removed

**The withdrawn RealityKit preview was reachable.** Its comment said *"it just cannot
be reached"*, but `AppSettings.init` loaded the stored flag. The toggle shipped in
exactly one build (`c75d26f`, 2026-08-02) and was withdrawn the next day
(`f40aaab`); a `true` left by that build would still route the review screen to a
renderer that scrambles every texture — on the one phone that matters. `init` now
ignores and clears the stored value.

**Two documents undercounted the Czech gap.** `CLAUDE.md` and
`docs/CODEMAPS/surfaces.md` said *"roughly 62"* English toasts. Measured: 137
`showToast` call sites, **2** with a Czech key, 105 unkeyed literals, 30 non-literal
arguments. `DEVICE-ROUND-r89.md` D1 had it right.

`docs/CODEMAPS/surfaces.md` also called `RealityMeshBuilder` / `RealityMeshPreview`
the RealityKit path "when one is needed". It is not a ready path; the entry now
says what is broken and where to start.

### Repository hygiene

Sixteen local branches already merged into `main` were deleted with `git branch -d`,
which refuses anything unmerged. **The remote was not touched:** `origin` still
carries 16 merged `claude/*` branches plus `claude/keen-pascal-2dee11`, whose one
unmerged commit (2026-06-09) syncs a `project.pbxproj` regenerated many times since.
Deleting remote branches is the owner's call.

### Deliberately left — dead or parked, and why it stays

* **The Mesh-mode capture path is unreachable.** Start Scan exists only in the
  idle/scanning surface, and the only way from a reviewed mesh back to idle is
  `discard()`, which resets `scanKind = .points`. It still keeps alive `startScan`'s
  `else` branch, `restartScan`'s `.mesh` case, `finishMeshScan`,
  `effectiveMeshConfig`, `meshObjectMode`, `liveCountIsTriangles`, sixteen
  `meshMode` sites in `ScanARView` and `MeshSceneBuilder.wireframe`. `ScanKind.mesh`
  itself is live — it marks a reviewed built or loaded model. This is capture code
  bound to ARKit; remove it in a round that can scan, not in one that cannot.
* **The octree reconstruction chain** — `AdaptiveOctree`, `AdaptiveMesher`,
  `AdaptiveSurfaceReconstructor`, 512 lines — is production-dead but tested and parked
  on purpose ([DEVICE-ROUND-r89.md](DEVICE-ROUND-r89.md) C1).
* **Content-adaptive capture** — `contentAdaptiveEnabled` is `false` in every shipped
  profile; kept, and tested, for a capture-side experiment.
* **The RealityKit preview files** — `RealityMeshBuilder` + `RealityMeshPreview`, 324
  lines — stay parked with the culling suspect written down; they are now genuinely
  unreachable.
