# HANDOFF → r77

_Written 2026-08-02 across r74–r77. Self-contained: read this and you can start.
It supersedes [HANDOFF-r74.md](HANDOFF-r74.md), whose §2.1 turned out to be a
measurement bug — see §2 below before you spend a round on it._

---

## 0. Where the code is

| | |
|---|---|
| **Branch** | `claude/cloud-mesh-postprocess-optimize-8cb455` |
| **Worktree** | `/Users/keks/Developer/Magic-camera/.claude/worktrees/cloud-mesh-postprocess-optimize-8cb455` |
| **HEAD** | `c75d26f` + the r77 chart-shatter telemetry (see §4) |
| **`main`** | 180+ commits stale. **Never build it.** |
| **Pushed?** | No. r74–r77 are local commits on the worktree branch. |

⚠️ The shell's cwd flaps between the main repo and the worktree mid-session. Use
`git -C "$W"` with an absolute `$W` for **every** git command, `-project <abs>`
for xcodebuild, and verify a commit landed with
`git -C "$W" show --stat --format="" HEAD` — the *file list* is what catches a
commit that went to the wrong tree.

`xcodegen generate` **from inside the worktree** after adding/removing files.

**When `xcodebuild` exits after three lines of output**, or `simctl list devices`
returns nothing, the Xcode services are wedged, not your code:

```bash
killall -9 XCBBuildService com.apple.CoreSimulator.CoreSimulatorService xcodebuild; pkill -9 -f SourceKitService
```

Only one simulator is installed here: **iPhone 17**. Batch edits, build once at
the end — the machine is slow, and a full build+test is ~8 minutes.

---

## 1. What r74–r77 changed, and what still needs a device

**Nothing below has been on a device.** Four commits are stacked; the single most
valuable next action is a device round, not more code.

| commit | what |
|---|---|
| `50288e9` | marching-cubes winding, sphere-snap gates, thin-subject clustering, gutter-flood cost, per-stage `bake timing` |
| `fc8333b` | Finer-room-detail switch, on-device scan naming, OperationRunner tests, autosave flush |
| `c75d26f` | RealityKit preview behind a switch |
| _r77_ | chart-shatter telemetry (`pad %`, `median chart px`, gate-search trace) |

### The three real defects r74 found

1. **Marching cubes wound every mesh inside-out.** `MarchingCubes.mesh` emitted
   `(0, 2, 1)` under a comment claiming the swap made faces point outward; it did
   the opposite. Bourke's table already winds outward for the "negative = inside"
   convention this field uses. Per-vertex normals are derived from the winding, so
   every reconstructed surface carried normals pointing **into** itself. In-app it
   hid behind double-sided materials and a bake that scores views on
   `abs(dot(normal, toCamera))` — it would show as inverted shading or culled
   front faces in a strict glTF / USDZ viewer.
   **Verify:** exported USDZ/GLB in AR Quick Look and a third-party viewer.

2. **Shape snapping rounded boxes.** The sphere fit accepted inliers within 72° of
   its radial direction — the *revolution* path's constant, where it only means
   "not a cap". On a 20 cm box a ~0.1 m sphere cuts a disc from each of the six
   faces that clears 72°; six discs are a third of the mesh, and snapping pulled
   the faces **18 mm out of flat**. Shape snapping is on by default, so any boxy
   subject was exposed. Two gates now: normals must agree with the sphere to ~20°
   (`sphereNormalAgreement`), and the patch must be genuinely curved
   (`maxSphereNormalResultant` — a 2 m sphere, the radius ceiling, bows 2.5 mm
   across a 20 cm patch, so a table top fits one perfectly).
   **Verify:** scan a boxy object; `shape snap` must read `spheres 0 · snapped 0`.
   Then a round one; `revolutions ≥ 1` with its decoration intact.

3. **Thin subjects lost 98 % of their points to clustering.** r73's funnel measured
   steel-rimmed glasses at `21945 → cluster 431`.
   `PointCloudSegmenter.isolateMainSubject` only absorbed clusters holding at
   least an eighth of the largest one. A thin rim is not one blob — it breaks into
   dozens of small components, and a floor tied to the *largest* excludes all of
   them by construction. Size was never the signal separating "my subject, in
   pieces" from "the thing behind it"; proximity is, and the existing
   no-larger-than-the-chosen-cluster rule already carries the anti-swallow
   guarantee. Growth is now iterated so a chain of fragments re-unites.
   **Verify:** the same glasses. `isolate funnel — … → cluster N`, N in thousands.

### The switches added (both default OFF)

- **Settings ▸ Finer room detail** — 20 mm room lattice floor instead of 28 mm,
  ~2× triangles. The constant did **not** move; this is the A/B the 28 mm floor
  has been waiting for. The `lattice` breadcrumb prints `floor 20 mm (fine)` when
  it is on. 🔴 The torn-paper regression (black holes, spikes through walls) is
  what this risks — compare the same room both ways before anyone argues for
  changing the default.
- **Settings ▸ RealityKit preview** (iOS 18+) — swaps the review preview's
  renderer. It draws the shaded orbit only; ruler, clip plane, walk mode, ghost
  placement and any non-shaded colour mode fall back to SceneKit automatically.

---

## 2. The test suite: resolved, do not re-open

The r74 handoff's first task was an unexplained "4 → 22 failure jump". **There was
no jump.** Built and ran the suite at the stated baseline `a598fb6`:

| | tests | assertion failures | failing cases |
|---|---|---|---|
| `a598fb6` | 247 | 22 | **14** |
| HEAD then | 288 | 22 | **the same 14** |

The "4" counted test cases through a grep that missed most of them; the "22" is
XCTest counting *assertions*. r70–r73 added 41 green tests and regressed nothing.

**Post-r77 floor: 322+ tests, 4 assertion failures in 3 cases.** All three are in
code the shipping pipeline never runs:

- `AdaptiveOctreeTests.testCurvedSubdividesFinerThanFlat` — a genuine float tie
  (`0.098750085` vs `0.09875008`); the two fixtures partition identically.
- `AdaptiveSurfaceReconstructorTests.testReconstructsAPlaneNearItsSurface` —
  returns nil for a dense plane.
- `MeshLouverSnapTests.testSlatStackEvensSpacing` — louver snap has been disabled
  in the pipeline since r56.

Anything beyond those three is new. **See §5 item 1: these should be fixed or
deleted, not carried.**

Counting rules that cost two rounds: count *cases* with `grep "' failed ("`, not
XCTest's tally; capture xcodebuild with `grep ": error:"`, not `^Test Case`, which
its timestamped lines defeat.

Six of the fourteen were bad tests, now fixed: coverage sampled exactly on sector
boundaries and blamed the tracker for the resulting 22/24; a `CGRect` compared for
exact equality after being rebuilt from its own corners; a "photographic"
JPEG-vs-PNG fixture that was a periodic sawtooth (the one shape PNG wins); a
paging fixture that was a single continuous plane — which unwraps to **one chart**
and therefore cannot page however large it is; an outlier test asserting that a
finite patch has no boundary; and a sphere tolerance predating the
relief-preserving snap it measures.

---

## 3. What to ask the user to scan

Ranked by what it verifies:

1. **A big room, then export USDZ.** Covers the winding fix (model not inside-out,
   shading not inverted), the new `bake timing` split, and memory.
2. **The steel-rimmed glasses.** `isolate funnel — … → cluster N` is the whole
   measurement.
3. **A boxy object** (speaker, book, drawer front). `shape snap` must be
   `spheres 0 · snapped 0`.
4. **A round object** (mug, pot) as the control — `revolutions ≥ 1`, decoration
   preserved.
5. **The same room twice, Finer room detail off then on** — the 4.3 A/B.
6. **A model with RealityKit preview on** — geometry, textures on every page,
   orbit/pinch, and that the review tools still bring back SceneKit.

---

## 4. Breadcrumbs added, and what each answers

| line | question it settles |
|---|---|
| `bake timing … gpu / fallback / repair / seam / gutters / jpeg` | which pass owns the ~15 s a page costs. Two cost models were wrong for want of exactly this split, and iOS has filed a `cpu_resource` report (90 s CPU over 139 s) against a big-room bake |
| `uv gate search — 0.75: N charts, d D \| … → gate G · pad P% · median chart M px` | whether chart shatter is actually costing the sheet. Every chart is padded on four sides, so the overhead is per-chart: one big chart pays the border once, 25 404 small ones pay it 25 404 times. `pad %` says how much of the sheet that is; `median chart px` says how close the charts are to being all border. The trace says whether the loose gate won by a hair or a mile — which decides whether the fix is the gate or the padding |
| `lattice … floor 20 mm (fine)` | which lattice floor the reconstruction actually ran at |

Rule that has paid off every round since r71: **add the breadcrumb before tuning.**
And: **a comment asserting an invariant is not evidence — grep first.** The
marching-cubes winding is the fourth bug in this project found sitting under a
comment claiming the opposite.

---

## 5. Recommended order for r77+

### 1. Decide the fate of the unwired code (cheap, unblocks the suite)

`AdaptiveOctree`, `AdaptiveSurfaceReconstructor` and `MeshLouverSnap` are built,
never wired, and are the **entire** remaining test-failure floor. Either finish
them or delete them. Carrying three permanent failures means every future round
starts by re-deciding whether the suite is green.

Notes if fixing: the adaptive stack was dropped because on noisy LiDAR it meshed
everything uniform-coarse at ~50 mm (worse than the shipping path). Louver snap
was disabled in r56 because it false-fired on the marching-cubes lattice — it read
a plain room as a "120-slat blind, period 2.8 cm" and moved 95 % of the vertices,
tearing black holes into every room. Re-enabling it needs triangle-**area**
density, not vertex-count density.

### 2. Device round on r74–r77 (see §3), then finish §2.2's CPU work

The `bake timing` split names the pass. Likely candidates, cheapest first:
the JPEG encode of an 8192² sheet (a hardware encoder path exists), and the
gutter flood (already ~4× cheaper in queue operations after r74, but the seed pass
is still a full 67 M-texel scan). Do **not** simply reduce the page count — that
is the texture-quality win the last four rounds bought.

### 3. Chart shatter, now that it is measured

Read `pad %` off a big-room diag. If padding is a large share, the levers are the
growth gate (already searched — read the trace) and `chartPadPx` (4 px on every
side; mip sampling is what it protects, so it cannot go to zero).

### 4. Tier 3.3 — `ScanTuning`

**Partly answered already: [SCAN-TUNING.md](SCAN-TUNING.md) maps all ~70 scan
constants, what each decides, and the traps around them, at zero risk.** Read that
before deciding whether moving the code is still worth it — the reason the item
existed was that nobody could find the constants, and a rationale comment is worth
more sitting next to the maths that reads it than filed in a blob.

If it is done anyway: move values without editing any of them in the same commit,
and assert every value in a test so a typo in the move cannot survive.

### 5. Tier 3.2 / 3.4 — decomposition

`SpatialScanViewModel` is 1734 + 1961 LOC; eight files exceed 800, the largest
2031. Also numerically neutral.

### 6. RealityKit, next steps

Once the preview is device-proven: ruler and clip plane on RealityKit (they need
hit-testing and a clipping material), then the point-cloud path. `MeshPageGeometry`
is deliberately outside the RealityKit availability gate so the page split stays
testable without a device.

### 7. User steps, unchanged

App Store Connect record + first Archive (registers the iCloud container and App
Group), screenshots (6.9"/6.5" iPhone + iPad), description, privacy label ("Data
Not Collected"), final name and bundle id.

---

## 6. Rules that have burned this project — do not relearn them

1. **A comment asserting an invariant is not evidence. Grep first.** Four bugs so
   far: Studio's "the mesh passes check `Task.isCancelled`" (zero such checks),
   r67's "candidate scoring runs per page" (hoisted above the loop), "peak memory
   is a single atlas however many pages" (no `autoreleasepool`), and r74's
   "reversed winding so faces point outward" (it pointed them inward).
2. **Validate atlas/geometry work against REAL device exports, never synthetics.**
   False results 4× so far. Exports are duplicated-corner soup — both sides of
   every triangle — so **halve before quoting triangle counts** and dedupe before
   any connectivity work.
3. **Geometry detail floor is ~cm** (15.3 mm room / 3.7 mm object local-plane
   RMS). Detail lives in the **texture**. Don't chase sub-cm geometry.
4. **Add the breadcrumb before tuning.**
5. **`cancel()` vs `requestStop()` is a real distinction.** `cancel()` invalidates
   (the data changed — discard, new scan). `requestStop()` keeps the result if it
   lands (resource pressure; the data is unchanged). Conflating them binned 94 s
   of completed, correct work. Now pinned by `OperationRunnerTests`.
6. **Integer division makes budget thresholds sharp** — `500_000 / 253_062 == 1`
   silently gave a big room one page.
7. **`SIMD3<Float>` is 16 bytes / 16-byte aligned.** Never load one straight from
   a 12-byte-strided buffer; it segfaults. Read component floats.
8. **A single chart cannot straddle two atlas pages.** The shelf packer spills
   whole charts, so a continuous surface — however large — pages exactly once.
   This invalidated a test fixture and would invalidate any paging benchmark built
   on a plane.
9. **Alert buttons dismiss the alert.** Any dialog that has to keep itself open
   (fill a field in place, show progress) must be a sheet.
