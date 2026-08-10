# r88 — five faults found by measuring the artefacts, not the code

Round r88 had something earlier rounds did not: the user's actual **scan files**
alongside the diagnostics export — a room point cloud, the room's textured USDZ,
and an object USDZ. Every fault below was found by measuring those files and then
going to the code with a number in hand. That order is the point of this note.

Device: iPhone17,1 · iOS 26.5.2 · exports `MagicCamera-Diagnostics-20260806-211622`
and `-20260810-095240`.

## What the user reported, and what it actually was

| Report | Cause |
|---|---|
| "bands of circles like a radar sweep", holes more sweeping never fills | `adaptiveSnap` quantising positions in shells around the phone |
| (not reported — found while looking) floor 2.78° off level, warped 12 cm | ICP roll/pitch compounding, invisible to `drag` |
| "u roomu to zlikvidovalo stůl" | the matte filter's hardcoded 0.65 confidence bar |
| "make 3d model dělá pravidelné placky" | the room's planar regulariser run on a subject |
| "zkazí mi to běžící scan" | tapping a subject called `clearAccumulation()` |
| (not reported) 59% of a room's texture synthesised, not photographed | triangle budget and atlas page budget never reconciled |

Commits: `d61eaaa`, `30e9f1b`, `e1553e7`, `1aa4c44`.

## The measurements, so the next round can repeat them

The scan files are the evidence. Parsing them takes a page of numpy; do it before
theorising.

**Is the cloud lattice-quantised?** Test what fraction of points sit *exactly* on
a `k × voxel` lattice — `|p/cell − round(p/cell)| < 1e-3` on all three axes. A
healthy cloud is ~0%. Scan 14 was 31.3%: 25.8% on 10 mm, 5.9% on 15 mm, 3.3% on
20 mm, which reads straight off as `adaptiveVoxel` multipliers ×2/×3/×4 at a 5 mm
voxel. Note the counter and the cloud disagree by design — `snapped` counts
intent at capture, and fusion then averages snapped points back off the lattice,
so a low on-lattice fraction does **not** clear the mechanism.

**Is the floor a plane or a slab?** Fit the floor robustly, then measure the
per-10 cm-tile height spread. Scan 14: 10.7 mm median, 23.8 mm p90 — a slab, not
a surface, because the same wall stored at two different lattices stacks instead
of fusing. Fit each quadrant separately as well: a *constant* tilt is one bad
rotation, a *varying* one (1.86°–3.86°) is drift accumulated during the sweep.

**Did a step delete something?** Height-profile the cloud and the delivered mesh
the same way and compare the same band. The room's table was 450 k points and two
obvious slabs in a bird's-eye render of the cloud, and simply absent from the
mesh — which turns "why did my table vanish" into "which step, between these two
files, removes points".

**Is a model flat?** Cluster the mesh's triangles by (normal, offset) and sum
area per plane. The lamp: 99.8% of its area in one plane, bbox 108 × 125 × **1**
mm. That is not a lamp.

Reading a USDZ from the command line: SceneKit loads it, but two traps cost half
an hour each. `SCNGeometryElement.primitiveCount` disagrees with the buffer on a
baked soup — derive the index count from `data.count / bytesPerIndex`. And
`SIMD3<Float>` has a **16-byte** stride, so writing `[SIMD3<Float>]` raw and
reading it as packed 12-byte triples shears x/y/z apart; the giveaway is a bbox
that comes out identical on all three axes. Flatten to `[Float]` first.

## What the fixes actually changed, and how to check them

Two of them are already confirmed on device by the second export:

- `tilt 0.00°` on all four scans, and the r88 room mesh's floor measures **0.03°**
  off level (was 2.78°). The ICP levelling holds.
- `snapped 0` on all three object scans. The room reported `snapped 1053755` —
  correctly: it reached 3.2 M against a 4 M cap, so it was over the 0.6 pressure
  gate and the coarsening was doing its actual job.

Still unverified, in the order the next round should read them:

1. `scan quality — … snapped N`: must be **0** on any scan that stays under 60%
   of its cap.
2. `scan icp — … tilt N°`: must stay **0.00**.
3. `scan quality — raw A → kept B`: the matte filter may no longer take more than
   a third. The r88 room lost 1,599,919 of 3,215,986 to it.
4. `surface cleanup — planes N` on an **Object** scan: must be **0**.
5. `texture-bake — … repaired N/M` against `bake budget — … pages ≤ P`: the r88
   room was 315,751/531,326 at one page. With the triangle budget now derived
   from the atlas, a one-page room should cap near 262 k triangles and repair far
   less.

## Left open, deliberately

**`surface holes — 44572 → 17757 open edges`** on the room. Not chased. Both
capture faults fixed this round produce holes — the confidence filter alone was
deleting half the cloud, and sparse regions are exactly what the reconstruction
leaves open — so the honest move is to re-measure a room captured with the fixes
before touching the hole filler. Tuning it now would be tuning against a number
that is about to move.

**Isolation's floor.** `isolate funnel — 28962 → mask 18740 → cluster 1174` on the
lamp: the guard at `max(800, working.count / 20)` passed it by 237 points, and the
comment above that guard describes this exact failure ("a mug reconstructing from
the top 4.6 cm of itself: 1762 triangles in 33 ms, squashed flat"). It is the same
bug, sitting just above the bar. The planar gate now stops the *consequence*
(a subject can no longer be flattened), but isolation still hands the
reconstruction a fragment. Fixing it by moving 1/20 to some other fraction is
guessing; the measurement that would settle it is whether the kept cluster is a
pancake, which needs the isolated cloud exported — worth adding as a debug export.

**Memory.** The room path peaked at 3144 MB with **231 MB** of headroom and four
`memory pressure — critical` events. It survived, and everything above makes it
cheaper, but the governor named in `06-appstore-readiness.md` is still not there.
