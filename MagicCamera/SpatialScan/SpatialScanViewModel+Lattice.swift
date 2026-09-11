//
//  SpatialScanViewModel+Lattice.swift
//  Magic Camera
//
//  How coarse a lattice a scan may be reconstructed on, and how the support
//  surface under an object is found. Every triangle-density diagnosis since
//  r63 has started here, so the reasoning lives with the constants rather
//  than in whichever operation happened to call them.
//

import SwiftUI

extension SpatialScanViewModel {


    /// Hard triangle ceiling for the per-triangle photo bake. The bake cost (and
    /// its atlas size) scales with triangles, and on a big un-isolated surface it
    /// ran for minutes — long enough to trip the ~90 s CPU-resource watchdog (seen
    /// as MetricKit cpu_resource exceptions on device). Any mesh over this is
    /// decimated first (`cappedForBake`); the texture carries the visual detail, so
    /// the result looks the same but bakes in bounded time. Isolated objects stay
    /// well under it, so they're never touched. 450 k (was 250 k): the uniform
    /// surface lattice now goes finer on rooms (the ceiling was what made a big
    /// room mesh into "illogical big triangles"), and decimating the finer mesh
    /// back down would re-open the crack + smearing problems the budget raises
    /// fixed before — the GPU bake is atlas-texel-bound, so the extra triangles
    /// cost little; only genuinely enormous scans should ever hit this.
    /// 900 k (was 450 k): the budget is what actually sets a room's geometry
    /// ceiling, and 450 k silently undid the resolution rule below. A 166 m²
    /// device flat at the Detailed target of 20 mm cells reconstructs to ~832 k
    /// triangles; capping that back to 450 k grid-clusters it to an effective
    /// 27 mm — paying the fine reconstruction and then throwing it away, via
    /// uniform clustering that is worse than reconstructing at 27 mm directly.
    /// The bake is atlas-texel-bound, so the extra triangles cost little there;
    /// they cost post-process passes and export size.
    nonisolated static let photoBakeTriangleBudget = 900_000
    /// The variable-resolution path affords more: the GPU bake's cost scales with
    /// atlas texels not triangles, and the area-proportional atlas assigns texels
    /// by area — so a denser mesh keeps its texture sharp. 600 k (was 320 k) so a
    /// BIG / multi-session space keeps enough triangles for its extent: at 320 k a
    /// large continuous scan came out with too few triangles for its area — coarse,
    /// faceted, "bulgy" walls the plane regulariser had too few vertices to snap
    /// flat, and visibly worse than the un-capped manual "Build Surface". Atlas-
    /// texel-bound bake, so the extra triangles barely cost time and the phone has
    /// the headroom; only genuinely enormous scans hit the crack-free uniform cap
    /// now. A single small room stays well under this untouched.
    nonisolated static let adaptiveBakeTriangleBudget = 600_000

    /// Decimates `mesh` until it fits `budget` triangles, coarsening the cluster
    /// grid until it does (or a floor is hit). Vertex-clustering decimation
    /// self-heals soup/atlas geometry (see [[soup-mesh-weld-rule]]), so it's safe
    /// to run on any mesh. A no-op when already under budget. Off-main, pure value
    /// math — bounds the heaviest review-time op so it can't run the CPU watchdog.
    nonisolated static func cappedForBake(_ mesh: MeshData, budget: Int) -> MeshData {
        guard mesh.triangleCount > budget else { return mesh }
        // Take the FINEST cluster grid whose decimation still fits the budget, so
        // the result lands just under it. The old fixed grid-140 first step
        // overshot badly on a big scan: an 867 k-triangle continuous room collapsed
        // to ~160 k in one step (coarse, faceted walls the regulariser couldn't
        // snap flat) even though the raised budget had room for ~4× that. Search
        // fine→coarse; return the first grid that fits, else the coarsest tried.
        var coarsest: MeshData?
        var grid = 336
        while grid >= 32 {
            let decimated = MeshDecimator.decimate(mesh, gridResolution: grid)
            if !decimated.isEmpty {
                if decimated.triangleCount <= budget { return decimated }
                coarsest = decimated
            }
            grid -= 32
        }
        return coarsest ?? mesh
    }

    /// Lattice resolution driven by the cloud's actual point density instead of a
    /// flat detail tier: a fixed tier divided a whole room's extent into coarse
    /// cells regardless of how densely it was scanned, so "changing detail barely
    /// helped". Here the cell size tracks the sampled surface density — finer where
    /// the scan is dense — capped by `cap` (per tier) so a large dense cloud can't
    /// blow the CPU/memory watchdog. Uses a cheap surface-area/count spacing
    /// estimate (O(1) after the bounding box) rather than a kd-tree pass, which on
    /// a multi-million-point cloud is exactly what tripped the watchdog before.
    /// `noiseFloorCell`, when set, caps the lattice at that coarsest cell — the
    /// room depth-noise floor. Passed by the caller from the SCAN TYPE, not the
    /// bounding box: an earlier size gate (`maxExtent >= 4`) skipped the floor
    /// on rooms under 4 m in every axis, so a small room the area rule drove to
    /// ~15 mm tore into black holes on device. Depth noise scales with RANGE
    /// (how far you stood), not with how big the room is — a 3 m room is scanned
    /// at the same distance as a 7 m one — so the caller keys this on room vs
    /// close-object capture, and nil (objects) keeps the fine lattice their own
    /// point spacing supports.
    nonisolated static func densityResolution(for cloud: PointCloud,
                                              fallback: Int, cap: Int,
                                              noiseFloorCell: Float? = nil) -> Int {
        latticeBound(for: cloud, fallback: fallback, cap: cap,
                     noiseFloorCell: noiseFloorCell).resolution
    }

    /// Every candidate limit on the lattice resolution plus the one that actually
    /// bound. The resolution alone is not diagnosable: the 2026-07-28 device room
    /// meshed at 42 mm cells while the log printed `floor 28 mm`, and nothing said
    /// whether the noise floor, the triangle budget, the narrow band or the point
    /// spacing was the binding term — four different fixes, no way to choose.
    /// (NEXT-CHAT rule 4: add the breadcrumb before tuning blind.)
    struct LatticeBound {
        let resolution: Int
        /// What the cloud's own point spacing supports.
        let supported: Int
        /// What the tier's triangle budget affords over the surface area.
        let budget: Int
        /// What the reconstructor's narrow-band cell ceiling allows.
        let band: Int
        /// Room depth-noise floor (`Int.max` for objects, which have none).
        let noiseFloor: Int

        /// Name of the term that produced `resolution` — the tuning lever.
        var binding: String {
            if resolution <= 24 { return "minimum" }
            let terms = [("points", supported), ("budget", budget),
                         ("band", band), ("noise-floor", noiseFloor)]
            return terms.first { $0.1 == resolution }?.0 ?? "clamp"
        }
    }

    nonisolated static func latticeBound(for cloud: PointCloud,
                                         fallback: Int, cap: Int,
                                         noiseFloorCell: Float? = nil) -> LatticeBound {
        guard cloud.count > 0, let box = cloud.boundingBox() else {
            let r = min(fallback, cap)
            return LatticeBound(resolution: r, supported: r, budget: r,
                                band: r, noiseFloor: Int.max)
        }
        let extent = box.max - box.min
        let maxExtent = max(extent.x, extent.y, extent.z, 0.01)
        let area = max(2 * (extent.x * extent.y + extent.y * extent.z + extent.x * extent.z), 1e-4)
        let spacing = (area / Float(cloud.count)).squareRoot()
        let supported = Int((maxExtent / max(spacing * 1.4, 1e-4)).rounded())
        // Cost ceiling, expressed where the cost actually lives: AREA. `cap`
        // used to be spent directly as "cells along the longest axis", which
        // means a different cell size in every room — the SAME room re-scanned
        // 2.7 m further down the flat went from a 6.42 m to a 9.14 m extent
        // and, at Detailed 256, from 2.51 cm to 3.57 cm cells: every chair in
        // it lost 42% of its triangle density for being scanned MORE (2788 →
        // 1525 tris/m², measured on both exports), while both clouds supported
        // far finer (8.2 / 8.7 mm point spacing).
        //
        // A marching-cubes surface emits ~2 triangles per cell² of area, so
        // the honest ceiling is the cell size that spends the triangle budget
        // over the area — `cell = √(2A/T)`. That is near-flat in room size
        // (√A, not the longest axis), and it leaves small subjects alone
        // entirely: an object's budget cell lands at ~1 mm, far below what its
        // own point spacing supports, so `supported` keeps binding there
        // exactly as before. The bbox area over-estimates the real surface
        // (18-35% on the device rooms), which biases the cell slightly coarse
        // — the safe direction: it under-spends the budget rather than
        // over-running it into the downstream clustering.
        let budget = Float(Self.reconstructionTriangleTarget(cap: cap))
        let budgetLimited = Int((maxExtent / max((2 * area / budget).squareRoot(), 1e-4)).rounded())
        // Narrow-band ceiling: SmoothSurfaceReconstructor gives up outright
        // (returns nil) at 4 M band cells. The band is the surface, ~3 cells
        // thick, so bound the cell size by the area it has to cover, with
        // margin.
        let bandLimited = Int((maxExtent / max((3 * area / 2_500_000).squareRoot(), 1e-4)).rounded())
        // Depth-noise floor (rooms only — see `noiseFloorCell`): below ~28 mm
        // cells the lattice out-resolves the LiDAR (multi-metre depth noise is
        // ~cm), so the "detail" it would add is crumpled noise shingles that
        // mesh as torn paper / black holes and shatter the UV unwrap (r43/r56).
        // Room geometry detail past ~cm doesn't exist in the data; it lives in
        // the photo texture.
        let noiseFloor = noiseFloorCell.map { Int((maxExtent / max($0, 1e-4)).rounded()) } ?? Int.max
        let resolution = max(24, min(min(min(supported, budgetLimited), bandLimited), noiseFloor))
        return LatticeBound(resolution: resolution, supported: supported,
                            budget: budgetLimited, band: bandLimited, noiseFloor: noiseFloor)
    }

    /// Coarsest room-lattice cell worth reconstructing: below this the surface
    /// lattice renders LiDAR depth noise rather than geometry (see the noise
    /// floor in `densityResolution`). 28 mm is device-proven; a candidate to
    /// revisit now that ICP has cut inter-frame registration noise from ~16 mm
    /// to ~2 mm, but only against a real scan — torn-paper regressions are
    /// catastrophic (black holes, spikes), so this does not move without proof.
    nonisolated static let roomLatticeFloorCell: Float = 0.028

    /// The floor Settings ▸ Finer room detail swaps in. 20 mm: a ~40 % finer cell,
    /// so roughly twice the triangles — enough to see whether the extra detail is
    /// real geometry or rendered depth noise, without the leap to ~10 mm that
    /// produced black holes on device in r64.
    nonisolated static let fineRoomLatticeFloorCell: Float = 0.020

    /// The floor a room reconstruction actually runs at. Reads UserDefaults
    /// directly (not the main-actor store) because both callers are inside
    /// detached reconstruction work.
    nonisolated static var activeRoomLatticeFloorCell: Float {
        ReconstructionSettings.fineRoomLatticeEnabled
            ? fineRoomLatticeFloorCell : roomLatticeFloorCell
    }

    /// Triangles the reconstruction may spend at a given tier cap. The tier is
    /// now a budget rather than an axis count: quartered at Draft, doubled by
    /// the time it reaches Detailed, and clamped to what the bake will actually
    /// keep — spending past `photoBakeTriangleBudget` only feeds the crack-free
    /// uniform clustering, which is strictly worse than having reconstructed at
    /// that size to begin with.
    nonisolated static func reconstructionTriangleTarget(cap: Int) -> Int {
        let scale = Float(max(cap, 1)) / 256
        let scaled = Float(photoBakeTriangleBudget) * scale * scale
        return max(50_000, min(photoBakeTriangleBudget, Int(scaled)))
    }

    /// Share of a cloud that must sit in one thin horizontal slab before the
    /// "capture already removed the support" claim is treated as disproved.
    ///
    /// The 2026-07-28 object scan measured **74%** in a 4.5 cm slab spanning its
    /// whole 30 × 43 cm footprint. But an absolute share alone is not enough to
    /// tell a tabletop from a subject, and getting that wrong is expensive in the
    /// dangerous direction — a false positive sends a clean cloud back through the
    /// geometric isolation, which is what decimated the mouse/plate. See
    /// `supportSlabExcess` for the second, scale-invariant condition.
    nonisolated static let supportSlabFraction: Float = 0.40

    /// How many times denser (points per centimetre of height) the densest slab
    /// must be than the rest of the cloud before it reads as a support surface.
    ///
    /// This is the condition that actually separates the two cases, and two unit
    /// tests were needed to arrive at it:
    ///
    /// 1. An absolute share alone fails, because **a sphere's surface has uniform
    ///    vertical density** (Archimedes' hat-box theorem) — a 12 cm ball puts a
    ///    full 50% of itself in any 6 cm band and trips a bare 40% bar.
    /// 2. Comparing against `slabHeight / cloudHeight` fails too: cloud height is
    ///    set by the most extreme outlier, so a handful of stray points below the
    ///    table changes the verdict. The device cloud's own height came from 725
    ///    points out of 62 143.
    ///
    /// Linear density is immune to both. Evenly spread ⇒ ratio 1.0 whatever the
    /// object's size or shape; the 2026-07-28 device tabletop ⇒ 46 273 pts over
    /// 4.5 cm against 15 224 over 6.8 cm = **4.6×**. 2.5 sits well clear of both.
    nonisolated static let supportSlabDensityRatio: Float = 2.5

    /// Whether a "support already cropped at capture" cloud still contains the
    /// support. Cheap horizontal-slab histogram rather than a plane fit: the
    /// support is by definition gravity-aligned, and the failure being caught is
    /// gross (three quarters of the cloud), not subtle.
    ///
    /// Logs `support check` either way — the branch taken here decides whether the
    /// subject gets isolated at all, and it was previously invisible.
    nonisolated static func supportSurvivedTheCrop(_ cloud: PointCloud) -> Bool {
        guard cloud.count >= 2_000, let box = cloud.boundingBox() else { return false }
        let positions = cloud.positions
        let height = box.max.y - box.min.y
        guard height > 0.02 else { return false }   // already a sheet; nothing to separate
        // 2 cm bins: thicker than LiDAR depth noise, thinner than any subject worth
        // scanning, so a tabletop lands in one or two and a subject spreads.
        let binSize: Float = 0.02
        let bins = max(1, Int((height / binSize).rounded(.up)))
        var histogram = [Int](repeating: 0, count: bins)
        for p in positions {
            let bin = min(bins - 1, max(0, Int((p.y - box.min.y) / binSize)))
            histogram[bin] += 1
        }
        // A slab is up to three adjacent bins (~6 cm) — a table edge plus its top.
        let slabBins = min(3, bins)
        guard bins > slabBins else { return false }   // cloud is barely taller than a slab
        var worst = 0
        for i in 0..<bins {
            worst = max(worst, histogram[i..<min(bins, i + slabBins)].reduce(0, +))
        }
        let fraction = Float(worst) / Float(cloud.count)
        // Points per centimetre of height, inside the slab vs everywhere else.
        let slabHeight = Float(slabBins) * binSize
        let restHeight = max(height - slabHeight, binSize)
        let slabDensity = Float(worst) / slabHeight
        let restDensity = Float(cloud.count - worst) / restHeight
        let ratio = slabDensity / max(restDensity, 1e-3)
        // BOTH conditions: it dominates the cloud AND it is a sheet, not a solid.
        let survived = fraction >= supportSlabFraction && ratio >= supportSlabDensityRatio
        Diagnostics.shared.log("support check", String(
            format: "densest %.0f cm slab holds %.0f%% of %d pts (%.1f× denser than the rest) → %@",
            slabHeight * 100, fraction * 100, cloud.count, ratio,
            survived ? "support SURVIVED the crop — isolating" : "crop trusted"))
        return survived
    }

    /// True when a cloud is essentially a flat sheet — its thinnest extent is a
    /// tiny fraction of its largest. Used to catch isolation collapsing a 3-D
    /// subject to a floor-parallel slice (the squashed-model bug).
    nonisolated static func isFlat(_ cloud: PointCloud) -> Bool {
        guard let box = cloud.boundingBox() else { return false }
        let e = box.max - box.min
        let dims = [e.x, e.y, e.z].sorted()
        return dims[2] > 0.03 && dims[0] < dims[2] * 0.15
    }

    /// Recovers index-aligned view directions for a cloud that is a pure subset
    /// of `source` — the contract the one-tap model and every subset edit relies
    /// on. Forwards to the canonical implementation on `ReconstructionPipeline`
    /// (kept there so the pipeline is standalone-testable without the view model);
    /// the many review-time call sites keep calling it here unchanged.
    nonisolated static func recoverViewDirections(for subset: PointCloud,
                                                  from source: PointCloud,
                                                  directions: [SIMD3<Float>]?) -> [SIMD3<Float>]? {
        ReconstructionPipeline.recoverViewDirections(for: subset, from: source, directions: directions)
    }

}
