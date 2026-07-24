//
//  ReconstructionPipeline.swift
//  Magic Camera
//
//  The shared cloud→surface spine that Build Surface (`reconstructMesh`) and the
//  one-tap model (`makeQuickModel`) both run. The two used to keep private copies
//  of the same sequence — confident cut → (bilateral denoise) → density subsample
//  → curvature prepass → outlier + stray removal → reconstruct → assemble
//  (small-component / long-edge / adaptive fill+erode) → surface cleanup — and a
//  fix to that sequence kept landing in only ONE path (rounds 11/13/25 were all
//  "we fixed it in reconstruct but not in makeQuickModel", or vice-versa). This
//  type is that spine, lifted out verbatim: a value struct that carries the cloud
//  and its index-aligned view directions (and, for Build Surface, supplied
//  normals) through each stage. Every stage only ever *removes* points, so the
//  directions/normals stay aligned by riding through the same subset — the exact
//  contract `recoverViewDirections` depends on.
//
//  Pure value math, ARKit-free — the callers own the parts that legitimately
//  differ (isolation, the reconstruction method, the object base-cut, texturing);
//  this only owns what was genuinely identical, so it can be unit-tested against
//  synthetic clouds without the view model.
//

import Foundation
import simd

struct ReconstructionPipeline {

    /// The cloud as it flows through the stages. Starts as the caller's input
    /// (isolated subject, or the full captured cloud) and shrinks with each cut.
    private(set) var cloud: PointCloud
    /// The recorder's per-point view rays, index-aligned to `cloud`. Carried
    /// through every subset so the reconstruction can orient off measured rays
    /// (normal = −ray) instead of estimated normals. nil once unavailable.
    private(set) var directions: [SIMD3<Float>]?
    /// Optional supplied normals (Build Surface's cached cloud normals), also
    /// index-aligned and carried through the subsets until outlier removal
    /// invalidates them (the denoised cloud re-estimates its own).
    private(set) var normals: [SIMD3<Float>]?

    init(cloud: PointCloud,
         directions: [SIMD3<Float>]?,
         normals: [SIMD3<Float>]? = nil) {
        self.cloud = cloud
        self.directions = directions
        self.normals = normals
    }

    // MARK: - Cloud stages (in pipeline order)

    /// Drop the least-reliable fused points first: low fused confidence is where
    /// the bleed/ghosts that survived carving sit, and they pull the surface
    /// around. Guarded so a dark/glossy (low-confidence) scan isn't gutted —
    /// only cuts when a clear majority (≥60 %) survives. Carries normals/rays
    /// through the same subset.
    mutating func dropLowConfidence(minConfidence: Float = 0.25) {
        let confident = cloud.confidentIndices(min: minConfidence)
        if confident.count >= 100, confident.count < cloud.count,
           Float(confident.count) >= Float(cloud.count) * 0.6 {
            if let n = normals, n.count == cloud.count { normals = confident.map { n[$0] } }
            if let d = directions, d.count == cloud.count { directions = confident.map { d[$0] } }
            cloud = cloud.subset(confident)
        }
    }

    /// Light edge-preserving denoise on the DENSE cloud before reconstruction — a
    /// gentle touch only. `SmoothSurfaceReconstructor`'s Gaussian field already
    /// averages out the ~1 cm LiDAR noise, so a wide bilateral pass on top of it
    /// double-smoothed the cloud-mode surface — which is exactly why Mesh mode
    /// (which skips this denoise entirely, reconstructing straight from ARKit's
    /// regularised mesh cloud) came out visibly SHARPER than Point-Cloud mode on
    /// the same room. The spatial sigma is now ≈1 point spacing (was 2.5×, ~27 mm
    /// on a big room), so it only knocks off outlier jitter and leaves the relief
    /// for the field to smooth once. Range sigma is the absolute noise (1.2 cm);
    /// positions shift along the fusion-ray normals, colours/rays untouched (count/
    /// order preserved, so `directions` stays aligned).
    mutating func bilateralDenoise(enabled: Bool) {
        guard enabled, let d = directions, d.count == cloud.count, cloud.count > 1_000,
              let spacing = BallPivotingMesher.meanSpacing(cloud.positions), spacing > 0 else { return }
        // ≈0.6× spacing, cap 7 mm (stepped down from 1.2×/15 → 0.9×/10 → here).
        // This is the second smoothing on top of the reconstructor's Gaussian
        // field, and it's why cloud-mode read a touch softer ("mazle") than the
        // field-only Mesh mode. A tight neighbourhood only knocks off per-point
        // jitter and leaves the fine relief for the field to smooth once — the
        // robust gap filler catches any hole a lighter denoise might leave, so
        // there's headroom to keep it crisp. Range sigma stays at the ~1.2 cm
        // LiDAR noise floor. (Not disabled outright — a hair of denoise still
        // stops raw depth speckle from faceting flat walls.)
        let sigmaS = min(spacing * 0.6, 0.007)
        let smoothed = PointCloudBilateralDenoiser.denoise(
            cloud.positions, normals: d.map { -$0 },
            spatialSigma: sigmaS, rangeSigma: 0.012, iterations: 1)
        var rebuilt = PointCloud()
        rebuilt.reserveCapacity(smoothed.count)
        for i in 0..<smoothed.count {
            rebuilt.append(position: smoothed[i], color: cloud.colors[i],
                           confidence: cloud.confidences[i])
        }
        cloud = rebuilt
        Diagnostics.shared.log("bilateral denoise",
            "\(smoothed.count) pts · σs \(Int((sigmaS * 1000).rounded()))mm · σr 12mm")
    }

    /// Hard density bound: a room-scale cloud (millions of points) fed straight
    /// into normal estimation + the signed field is what tripped the CPU/memory
    /// watchdog. Keep one representative point per half-cell — the surface is
    /// unchanged but the job becomes finite — carrying normals/rays through the
    /// same subsample so the measured orientation stays valid. The caller keeps
    /// the full cloud as the colour source for texturing.
    mutating func subsample(resolution: Int) {
        let sample = cloud.reconstructionSampleIndices(resolution: resolution)
        if sample.count >= 100 && sample.count < cloud.count {
            if let n = normals, n.count == cloud.count { normals = sample.map { n[$0] } }
            if let d = directions, d.count == cloud.count { directions = sample.map { d[$0] } }
            cloud = cloud.subset(sample)
        }
    }

    /// Optional curvature pre-pass: thin flat regions before meshing while
    /// keeping edges/relief dense, carrying the index-aligned normals/directions
    /// through the same subsample so the measured rays stay valid.
    mutating func curvaturePrepass(enabled: Bool) {
        guard enabled, cloud.count > 2_000,
              let spacing = BallPivotingMesher.meanSpacing(cloud.positions) else { return }
        let curvature = PointCloudCurvature.estimate(cloud)
        let kept = PointCloudAdaptiveDownsampler.keptIndices(
            cloud, curvatures: curvature, spacing: spacing)
        if kept.count >= 1_000 && kept.count < cloud.count {
            if let n = normals, n.count == cloud.count { normals = kept.map { n[$0] } }
            if let d = directions, d.count == cloud.count { directions = kept.map { d[$0] } }
            cloud = cloud.subset(kept)
        }
    }

    /// Shed the flying-pixel bleed halo before meshing. Statistical outlier
    /// removal drops sparse-neighbourhood points (it keeps dense disconnected
    /// geometry, so it's safe on multi-object scenes), then stray-cluster removal
    /// sheds detached floater blobs SOR keeps — before reconstruction bridges them
    /// into the surface where mesh small-component removal can't reach. Rays
    /// re-align by position (a pure subset); supplied normals are dropped so the
    /// mesher re-estimates them on the denoised cloud.
    mutating func removeOutliersAndStrays() {
        guard cloud.count > 1_000 else { return }
        var denoised = PointCloudDenoiser.removeOutliers(cloud, neighbors: 8, stdRatio: 1.5)
        denoised = PointCloudSegmenter.removeStrayClusters(denoised)
        if denoised.count >= 1_000, denoised.count < cloud.count {
            directions = Self.recoverViewDirections(for: denoised, from: cloud, directions: directions)
            normals = nil
            cloud = denoised
        }
    }

    // MARK: - Mesh stages (post-reconstruction, shared)

    /// The shared post-reconstruction assembly: drop the disconnected floaters
    /// reconstruction leaves around the surface (bleed bubbles SOR didn't catch)
    /// and trim the run-away boundary edges. On the variable-resolution path,
    /// close the small interior pinholes a cell in a data gap leaves, THEN erode
    /// the boundary fringe — fill first, because erosion peels every boundary
    /// (including the rim of each small hole), so eroding first would widen
    /// exactly the holes the fill is about to close (the 07-05 "holes despite
    /// green density" bug). Stays open — base capping is the model path's job.
    /// `keepFraction`: minimum component size relative to the largest. Isolated
    /// OBJECT scans pass 0.01 (was the 0.05 default): when a thin connector — a
    /// planter's stem/foot — gets eroded (carving + outlier filtering are hard
    /// on thin structures), the subject splits and the smaller piece used to
    /// vanish at 5% ("the top levitated over the base" — better to keep both
    /// parts than silently delete one). The subject is already isolated (ROI +
    /// carving + SOR + strays), so what's left near it is overwhelmingly real;
    /// surfaces keep 0.05. The thin-structure erosion itself is a separate,
    /// open problem.
    static func assemble(_ mesh: MeshData, adaptive: Bool,
                         keepFraction: Float = 0.05) -> MeshData {
        var m = mesh.removingSmallComponents(minFraction: keepFraction).trimmingLongEdges()
        if adaptive {
            m = fillingInteriorPinholes(m)
            // One erosion pass, not two: erosion removes every triangle with ≥2
            // boundary edges, which on a holey mesh eats the thin strips between
            // holes and MERGES them into bigger black gaps. One pass sheds the worst
            // fringe flakes without cascading the holes wider.
            m = m.erodingBoundaryFlakes(passes: 1)
        }
        return m
    }

    /// Closes the interior holes reconstruction leaves on a sparse cloud (a cell
    /// whose corner sits in a data gap is skipped, and edge trimming / decimation
    /// nick marginal triangles) while leaving every real opening alone: only loops
    /// that are both bounded (≤ 200 edges) and physically small (≤ 2.5 m around)
    /// qualify — a window is ≥ 3 m of perimeter and a doorway ≥ 5 m, so those and
    /// the outer scan boundary never close. Raised from 96 edges / 1.5 m because a
    /// sparse room left holes bigger than that gate could reach (the scattered
    /// black gaps), and a 2.5 m wall hole is a reconstruction gap to fill, not a
    /// real opening.
    static func fillingInteriorPinholes(_ mesh: MeshData) -> MeshData {
        let before = mesh.indices.count
        // 500-edge budget (was 200): a device room left scattered empty triangles
        // on well-covered walls — small holes whose boundary loop is longer than
        // 200 edges (a ragged reconstruction gap threads a long perimeter around a
        // small area). The ≤2.5 m perimeter cap still protects real openings, and
        // the phone has the headroom, so cast a wider net to solidify the walls.
        let filled = MeshHoleFiller.fill(mesh, maxHoleEdges: 500) { loop, vertices in
            var perimeter: Float = 0
            for (i, v) in loop.enumerated() {
                let next = vertices[Int(loop[(i + 1) % loop.count])]
                perimeter += simd_distance(vertices[Int(v)], next)
            }
            return perimeter <= 2.5
        }
        let added = (filled.indices.count - before) / 3
        if added > 0 {
            Diagnostics.shared.log("solid fill", "+\(added) tris · pinholes ≤2.5m")
        }
        return filled
    }

    /// Automatic clean finish for open surfaces: flatten the walls/floor, shed
    /// reconstruction noise, and — on the variable-resolution path — coarsen the
    /// flat regions to big triangles (kept sharp by the area-proportional atlas).
    /// Self-gating: an organic shape with no large plane passes through untouched.
    /// Logs the `surface cleanup` breadcrumb the device diagnostics read.
    static func surfaceCleanup(_ mesh: MeshData, baseResolution: Int,
                               adaptiveDecimate: Bool, seedPlanes: [SeedPlane]) -> MeshData {
        let cleaned = SurfaceCleanup.clean(mesh, baseResolution: baseResolution,
                                           adaptiveDecimate: adaptiveDecimate,
                                           seedPlanes: seedPlanes)
        Diagnostics.shared.log("surface cleanup", cleaned.summary)
        return cleaned.mesh
    }

    // MARK: - View-direction recovery

    /// Recovers index-aligned view directions for a cloud that is a pure subset
    /// of `source`. The masking / isolation steps (`SurfaceMask.cleaned`,
    /// `KeyframeSubjectFilter.filter`, `PointCloudSegmenter.isolateMainSubject`)
    /// only ever *remove* points — they append `source.positions[i]` verbatim —
    /// so every kept point still sits at its original position and its measured
    /// camera direction can be looked up by position. That is what lets the
    /// one-tap model reuse Fusion's view rays (the robust outward orientation
    /// Build Surface uses) even though isolation returns a fresh cloud with no
    /// index map. Returns nil — caller falls back to estimated normals — when the
    /// source has no usable rays or, defensively, when most points fail to match
    /// (the subset assumption broke, e.g. a transformed cloud).
    static func recoverViewDirections(for subset: PointCloud,
                                      from source: PointCloud,
                                      directions: [SIMD3<Float>]?) -> [SIMD3<Float>]? {
        guard let directions, directions.count == source.count,
              source.count > 0, subset.count > 0 else { return nil }
        // Manual / surface mode passes the cloud through verbatim — already aligned.
        if subset.count == source.count { return directions }
        guard let box = source.boundingBox() else { return nil }

        // Cheap density-derived cell (no kd-tree / grid pass): ~one source point
        // per cell on average, so the 3×3×3 search around each subset point finds
        // its verbatim copy at distance ~0.
        let extent = box.max - box.min
        let volume = max(extent.x, 0.005) * max(extent.y, 0.005) * max(extent.z, 0.005)
        let cell = max(cbrtf(volume / Float(source.count)) * 1.5, 1e-4)
        @inline(__always) func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        buckets.reserveCapacity(source.count)
        for i in 0..<source.count { buckets[key(source.positions[i]), default: []].append(i) }

        var out = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, -1), count: subset.count)
        var matched = 0
        for i in 0..<subset.count {
            let p = subset.positions[i]
            let base = key(p)
            var bestD = Float.infinity
            var bestIdx = -1
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        guard let bucket = buckets[base &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                        for idx in bucket {
                            let d = simd_distance_squared(source.positions[idx], p)
                            if d < bestD { bestD = d; bestIdx = idx }
                        }
                    }
                }
            }
            if bestIdx >= 0 {
                out[i] = directions[bestIdx]
                if bestD <= cell * cell { matched += 1 }
            }
        }
        // A genuine subset matches (almost) every point at distance ~0; if it
        // doesn't, the positions were moved and the rays no longer apply.
        guard matched >= (subset.count * 9) / 10 else { return nil }
        return out
    }
}
