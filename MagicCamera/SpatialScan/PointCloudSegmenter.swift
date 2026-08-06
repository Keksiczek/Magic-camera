//
//  PointCloudSegmenter.swift
//  Magic Camera
//
//  Object isolation for scanned point clouds:
//
//    1. RANSAC dominant-plane detection — finds the supporting surface
//       (floor / table) under the subject.
//    2. Euclidean clustering — connected components over a voxel adjacency
//       graph split the remaining points into separate objects.
//
//  `isolateMainSubject` chains both: strip the support plane, cluster what is
//  left and keep the most central large cluster. Pure value math — ARKit-free,
//  off-main-thread friendly and unit-testable.
//

import simd

enum PointCloudSegmenter {
    struct Plane {
        var normal: SIMD3<Float>   // unit
        var d: Float               // plane: dot(normal, x) + d = 0
        var inlierCount: Int

        func distance(to p: SIMD3<Float>) -> Float {
            abs(simd_dot(normal, p) + d)
        }
    }

    struct IsolationResult {
        var cloud: PointCloud
        var removedPlanePoints: Int
        var clusterCount: Int
        var keptPoints: Int
        /// How many distinct subjects were kept — one per anchor the user set,
        /// after anchors landing on the same object collapse together.
        var subjectCount: Int = 1
    }

    // MARK: - RANSAC plane

    /// Detects the dominant plane, or nil when no plane holds at least
    /// `minInlierFraction` of the points. `tolerance` defaults to ~1.5× the
    /// mean point spacing.
    static func detectDominantPlane(_ cloud: PointCloud,
                                    iterations: Int = 128,
                                    tolerance: Float? = nil,
                                    minInlierFraction: Float = 0.12,
                                    up: SIMD3<Float>? = nil,
                                    horizontalBias: Float = 0,
                                    seed: UInt64 = 0x5EED) -> Plane? {
        let n = cloud.count
        guard n >= 50 else { return nil }
        let positions = cloud.positions
        let eps = tolerance ?? max((BallPivotingMesher.meanSpacing(positions) ?? 0.01) * 1.5, 0.008)

        var rng = SplitMix64(seed: seed)
        var best: Plane?
        var bestScore: Float = 0
        // Score on a stride sample so RANSAC stays cheap on million-point clouds.
        let sampleStride = max(n / 20_000, 1)
        let sampledCount = (n + sampleStride - 1) / sampleStride

        for _ in 0..<iterations {
            let i = Int(rng.next() % UInt64(n))
            let j = Int(rng.next() % UInt64(n))
            let k = Int(rng.next() % UInt64(n))
            guard i != j, j != k, i != k else { continue }
            let a = positions[i]
            let normalRaw = simd_cross(positions[j] - a, positions[k] - a)
            let len = simd_length(normalRaw)
            guard len > 1e-9 else { continue }
            let normal = normalRaw / len
            let d = -simd_dot(normal, a)

            var inliers = 0
            var idx = 0
            while idx < n {
                if abs(simd_dot(normal, positions[idx]) + d) <= eps { inliers += 1 }
                idx += sampleStride
            }
            // Gravity-aware scoring: the support surface under a scanned object is
            // horizontal, so when an `up` axis is supplied a near-horizontal plane
            // is preferred over a larger vertical one (a wall, or the flat side of
            // a box). With `horizontalBias == 0` this stays plain max-inlier RANSAC,
            // unchanged for callers that don't pass an up vector.
            let horizontality = up.map { abs(simd_dot(normal, $0)) } ?? 1
            let score = Float(inliers) * (1 - horizontalBias + horizontalBias * horizontality)
            if score > bestScore {
                bestScore = score
                best = Plane(normal: normal, d: d, inlierCount: inliers)
            }
        }

        guard var plane = best,
              Float(plane.inlierCount) >= Float(sampledCount) * minInlierFraction else { return nil }
        // Re-count inliers over the full cloud so the reported count is exact.
        var exact = 0
        for p in positions where plane.distance(to: p) <= eps { exact += 1 }
        plane.inlierCount = exact
        return plane
    }

    /// Returns the cloud minus the plane's inliers (within `tolerance`).
    static func removingPlane(_ cloud: PointCloud, plane: Plane,
                              tolerance: Float? = nil) -> PointCloud {
        let eps = tolerance ?? max((BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01) * 1.5, 0.008)
        var out = PointCloud()
        out.reserveCapacity(cloud.count - plane.inlierCount)
        for i in 0..<cloud.count where plane.distance(to: cloud.positions[i]) > eps {
            out.append(position: cloud.positions[i], color: cloud.colors[i],
                       confidence: cloud.confidences[i])
        }
        return out
    }

    /// Cloud minus the plane's inliers *and* everything on the far (−up) side of
    /// it — so an object resting on a detected support surface is lifted cleanly
    /// off the floor/table rather than left bridged to its leftover points (which
    /// otherwise fuse the object and floor into one cluster).
    static func removingPlaneAndBelow(_ cloud: PointCloud, plane: Plane,
                                      up: SIMD3<Float>, tolerance: Float? = nil) -> PointCloud {
        let eps = tolerance ?? max((BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01) * 1.5, 0.008)
        // Orient the plane normal along `up` so the object's side is unambiguous;
        // flipping the normal flips the offset with it.
        let flip = simd_dot(plane.normal, up) < 0
        let normal = flip ? -plane.normal : plane.normal
        let d = flip ? -plane.d : plane.d
        var out = PointCloud()
        out.reserveCapacity(cloud.count)
        for i in 0..<cloud.count where simd_dot(normal, cloud.positions[i]) + d > eps {
            out.append(position: cloud.positions[i], color: cloud.colors[i],
                       confidence: cloud.confidences[i])
        }
        return out
    }

    // MARK: - Euclidean clustering

    /// Splits the cloud into clusters of points whose voxels touch (26-adjacency
    /// on a lattice of `cellMultiplier` × mean spacing). Returned index lists are
    /// sorted largest-first.
    static func clusters(_ cloud: PointCloud, cellMultiplier: Float = 3) -> [[Int]] {
        let n = cloud.count
        guard n > 0 else { return [] }
        let spacing = BallPivotingMesher.meanSpacing(cloud.positions) ?? 0.01
        let cell = max(spacing * cellMultiplier, 0.004)

        var voxelPoints: [SIMD3<Int32>: [Int]] = [:]
        voxelPoints.reserveCapacity(n)
        for (i, p) in cloud.positions.enumerated() {
            let key = SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                                   Int32((p.y / cell).rounded(.down)),
                                   Int32((p.z / cell).rounded(.down)))
            voxelPoints[key, default: []].append(i)
        }

        var visited = Set<SIMD3<Int32>>()
        visited.reserveCapacity(voxelPoints.count)
        var result: [[Int]] = []

        for start in voxelPoints.keys where !visited.contains(start) {
            // BFS flood fill over occupied 26-neighbour voxels.
            var stack: [SIMD3<Int32>] = [start]
            visited.insert(start)
            var members: [Int] = []
            while let key = stack.popLast() {
                members.append(contentsOf: voxelPoints[key] ?? [])
                for dz in Int32(-1)...1 {
                    for dy in Int32(-1)...1 {
                        for dx in Int32(-1)...1 {
                            let neighbor = key &+ SIMD3<Int32>(dx, dy, dz)
                            if voxelPoints[neighbor] != nil, !visited.contains(neighbor) {
                                visited.insert(neighbor)
                                stack.append(neighbor)
                            }
                        }
                    }
                }
            }
            result.append(members)
        }
        result.sort { $0.count > $1.count }
        return result
    }

    /// Extracts a subset cloud from point indices.
    static func subset(_ cloud: PointCloud, indices: [Int]) -> PointCloud {
        var out = PointCloud()
        out.reserveCapacity(indices.count)
        for i in indices {
            out.append(position: cloud.positions[i], color: cloud.colors[i],
                       confidence: cloud.confidences[i])
        }
        return out
    }

    /// Sheds detached speck clusters — the dense flying-pixel blobs that
    /// statistical outlier removal deliberately keeps ("keeps dense disconnected
    /// geometry") and that mesh small-component removal misses, because surface
    /// reconstruction bridges a near-surface blob into the main mesh before that
    /// runs. Clustering at `cellMultiplier × spacing` only separates geometry
    /// that is genuinely disconnected (a halo hugging the surface stays merged
    /// and is left to carving/SOR), so this targets exactly the snowstorm.
    ///
    /// Keeps the largest cluster plus any cluster at least `keepFraction` of it
    /// (or `absoluteFloor` points), and drops the rest. Returns the input
    /// unchanged when there is only one cluster, when nothing qualifies as a
    /// stray, or when the cut would remove more than half the cloud — so a clean
    /// scan or a genuine multi-object / fragmented scene is never gutted.
    static func removeStrayClusters(_ cloud: PointCloud,
                                    keepFraction: Float = 0.02,
                                    absoluteFloor: Int = 80) -> PointCloud {
        guard cloud.count >= 200 else { return cloud }
        let parts = clusters(cloud)                       // largest-first
        guard parts.count > 1, let largest = parts.first?.count else { return cloud }
        let threshold = max(Int(Float(largest) * keepFraction), absoluteFloor)
        var kept: [Int] = []
        kept.reserveCapacity(cloud.count)
        for part in parts where part.count >= threshold { kept.append(contentsOf: part) }
        // Never gut the cloud: only act when a dominant body clearly remains.
        guard kept.count < cloud.count, kept.count >= max(200, cloud.count / 2) else {
            return cloud
        }
        return subset(cloud, indices: kept)
    }

    // MARK: - One-tap isolation

    /// Isolation for a cloud that a **photo mask has already decided**: strip the
    /// support plane, shed detached floaters, and keep everything else.
    ///
    /// This is Apple's trust order, and the reason their object crop reads so
    /// much cleaner than a purely geometric one. Segmentation is far easier in
    /// image space than in 3D, so when a Vision subject mask has been intersected
    /// across enough views, that hull IS the subject — geometry's remaining job
    /// is to drop specks, not to re-open the question of which body is the real
    /// one.
    ///
    /// Letting it re-open that question is what cost this app two device rounds:
    /// clustering overruled the mask and kept a fragment both times (r87's
    /// steel-rimmed glasses, r88's mug reconstructing as its own top 4.6 cm).
    /// `removeStrayClusters` cannot do that — it keeps the dominant body plus
    /// anything sizeable and explicitly refuses to cut more than half.
    static func isolateMaskedSubject(_ cloud: PointCloud,
                                     up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)) -> IsolationResult? {
        guard cloud.count >= 100 else { return nil }
        let (working, removedPlane) = strippingSupportPlane(cloud, up: up)
        // A tighter keep-fraction than the standalone stray filter uses. Its
        // default 2 %-of-the-largest is tuned for a raw cloud, where a fifth of a
        // percent could be anything; here the mask has already ruled on what is
        // subject, so a cluster inside the hull earns the benefit of the doubt
        // and only genuinely detached specks go. The same "floor relative to the
        // largest" that cost a pair of glasses 98 % of its points in r74 would
        // otherwise quietly drop a small second object out of a hull that
        // deliberately included it.
        let kept = removeStrayClusters(working, keepFraction: 0.005)
        guard kept.count >= 30 else { return nil }
        return IsolationResult(cloud: kept,
                               removedPlanePoints: removedPlane,
                               clusterCount: clusters(kept).count,
                               keptPoints: kept.count,
                               subjectCount: 1)
    }

    /// Single-subject isolation — the historical entry point, unchanged in
    /// behaviour. Prefer `isolateSubjects` when the user may have picked more
    /// than one thing.
    static func isolateMainSubject(_ cloud: PointCloud,
                                   up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                                   anchor: SIMD3<Float>? = nil) -> IsolationResult? {
        isolateSubjects(cloud, up: up, anchors: anchor.map { [$0] } ?? [])
    }

    /// Strips the dominant support plane and keeps the subjects the user picked —
    /// one per anchor, each re-united from its own fragments. With no anchors it
    /// keeps the best single cluster: the largest one, biased toward the centre of
    /// the scanned volume (the subject is normally what the user orbited around,
    /// not wall fragments).
    ///
    /// Anchors that land on the same object collapse to one subject, so tapping a
    /// mug twice keeps one mug rather than counting it twice.
    static func isolateSubjects(_ cloud: PointCloud,
                                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                                anchors: [SIMD3<Float>] = []) -> IsolationResult? {
        guard cloud.count >= 100 else { return nil }

        let (working, removedPlane) = strippingSupportPlane(cloud, up: up)
        let parts = clusters(working)
        guard let largest = parts.first, largest.count >= 30 else { return nil }

        var centroids = [SIMD3<Float>](repeating: .zero, count: parts.count)
        for (i, part) in parts.enumerated() {
            var sum = SIMD3<Float>.zero
            for idx in part { sum += working.positions[idx] }
            centroids[i] = sum / Float(part.count)
        }

        // One seed cluster per subject the user picked. Duplicates collapse, so
        // two taps on the same mug are one mug.
        var seeds: [Int] = []
        if anchors.isEmpty {
            seeds = [centreBiasedCluster(parts, positions: working.positions,
                                         centroids: centroids, centre: working.centroid())]
        } else {
            let spacing = BallPivotingMesher.meanSpacing(working.positions) ?? 0.01
            let reuniteGap = max(spacing * Self.bodyReuniteCells, 0.06)
            for anchor in anchors {
                let near = nearestCluster(to: anchor, parts: parts, positions: working.positions)
                let i = bodyCluster(near: near, parts: parts, centroids: centroids,
                                    positions: working.positions, gap: reuniteGap)
                if !seeds.contains(i) { seeds.append(i) }
            }
        }
        guard !seeds.isEmpty else { return nil }

        // Every seed is claimed up front so one subject's growth can never swallow
        // another's — the user pointed at both, which outranks any proximity rule.
        var absorbed = Set(seeds)
        var keepIndices: [Int] = []
        for seed in seeds {
            keepIndices.append(contentsOf: growSubject(seed: seed, parts: parts,
                                                       centroids: centroids,
                                                       positions: working.positions,
                                                       absorbed: &absorbed))
        }
        let kept = subset(working, indices: keepIndices)
        return IsolationResult(cloud: kept,
                               removedPlanePoints: removedPlane,
                               clusterCount: parts.count,
                               keptPoints: kept.count,
                               subjectCount: seeds.count)
    }

    /// The cluster holding the point nearest `anchor`. Trusting the user's tap
    /// (Apple-style) rather than the largest blob — which is often the table or
    /// wall the object sits against — is the main lever for "it doesn't pick the
    /// object like Apple does".
    private static func nearestCluster(to anchor: SIMD3<Float>, parts: [[Int]],
                                       positions: [SIMD3<Float>]) -> Int {
        var best = 0
        var nearest = Float.infinity
        for (i, part) in parts.enumerated() {
            for idx in part {
                let d = simd_distance_squared(positions[idx], anchor)
                if d < nearest { nearest = d; best = i }
            }
        }
        return best
    }

    /// Lifts the subject off whatever it stands on, and reports how many points
    /// that cost. Shared by every isolation path so "the floor is gone" means the
    /// same thing whichever one ran.
    ///
    /// Scans are gravity-aligned (ARKit `.gravity` world alignment), so the
    /// support surface is horizontal — plane detection is biased toward it rather
    /// than toward whichever flat region happens to carry the most points.
    private static func strippingSupportPlane(_ cloud: PointCloud, up: SIMD3<Float>)
        -> (cloud: PointCloud, removed: Int) {
        guard let plane = detectDominantPlane(cloud, up: up, horizontalBias: 0.7) else {
            return (cloud, 0)
        }
        // Prefer lifting the object off the surface (drop the plane *and*
        // everything below it). Only when that keeps almost nothing — a plane
        // detected above the subject rather than under it — fall back to plain
        // two-sided inlier removal.
        let lifted = removingPlaneAndBelow(cloud, plane: plane, up: up)
        let stripped = lifted.count >= 50 ? lifted : removingPlane(cloud, plane: plane)
        guard stripped.count >= 50 else { return (cloud, 0) }
        return (stripped, cloud.count - stripped.count)
    }

    /// The BODY the tapped cluster belongs to.
    ///
    /// A tap says WHERE the subject is, not how big it is, and a user aiming at a
    /// mug with a lamp in it taps whatever is facing them — often a rim or a
    /// shade, which clusters separately from the body below it. Seeding on that
    /// small cluster was catastrophic: `growSubject`'s anti-swallow rule refuses
    /// anything LARGER than its seed, so the body could never join, and a 321 k
    /// point object scan reconstructed as the top 4.6 cm of itself — 2.5 % of the
    /// cloud, 1762 triangles, visibly squashed flat.
    ///
    /// So before growing, walk up: if a bigger cluster lies within reach of the
    /// tapped one, adopt it. The anti-swallow guarantee is not weakened — it is
    /// strengthened, because the size cap and the reach are then measured from
    /// the real body instead of from a fragment of it. Iterated a few times so a
    /// rim → wall → body chain arrives at the body.
    /// How far apart two clusters of ONE object may be, as a multiple of the
    /// cloud's mean point spacing.
    ///
    /// It has to scale, and it has to be several cells wide. `clusters` splits on
    /// a lattice of 3 × spacing with 26-adjacency, so any two distinct clusters
    /// are already at least ~2 cells apart BY CONSTRUCTION — a fixed threshold
    /// smaller than that can never fire, and one measured in centimetres means
    /// something different on a 3 mm object scan than on a 2 cm room sweep. Four
    /// cells is close enough to read as "the same thing, with a hole in the
    /// scan", and far enough from the 1.8× growth reach that this only ever
    /// promotes a seed the growth would then have kept anyway.
    private static let bodyReuniteCells: Float = 12   // 4 × the 3-spacing cluster cell

    /// Measured between NEAREST POINTS, not centroids: a tall body's centroid is
    /// far from a feature sitting on top of it — a 12 cm mug's centroid is 12 cm
    /// from its own rim — while the surfaces are touching. Centroid distance
    /// answers "are these the same size and place", which is not the question.
    private static func bodyCluster(near seed: Int, parts: [[Int]],
                                    centroids: [SIMD3<Float>],
                                    positions: [SIMD3<Float>],
                                    gap: Float) -> Int {
        var current = seed
        for _ in 0..<3 {
            var best = current
            for (i, part) in parts.enumerated() where part.count > parts[best].count {
                // Cheap reject on centroids before the O(n·m) surface test: two
                // clusters whose centroids are further apart than both their
                // radii plus the gap cannot have surfaces within it.
                let span = radius(of: parts[current], around: centroids[current],
                                  positions: positions)
                    + radius(of: part, around: centroids[i], positions: positions)
                guard simd_distance(centroids[i], centroids[current]) <= span + gap,
                      surfaceGap(parts[current], part, positions: positions,
                                 within: gap) <= gap
                else { continue }
                best = i
            }
            if best == current { return current }
            current = best
        }
        return current
    }

    private static func radius(of part: [Int], around centre: SIMD3<Float>,
                               positions: [SIMD3<Float>]) -> Float {
        var r: Float = 0
        for idx in part { r = max(r, simd_distance(positions[idx], centre)) }
        return r
    }

    /// Smallest distance between any point of `a` and any point of `b`, giving up
    /// as soon as it is under `bodyReuniteGap` (the answer is a yes/no, and the
    /// common case exits in the first few probes). Strided on large clusters so a
    /// 300 k-point scan stays bounded.
    private static func surfaceGap(_ a: [Int], _ b: [Int],
                                   positions: [SIMD3<Float>], within: Float) -> Float {
        let cap = 2_000
        let strideA = max(1, a.count / cap), strideB = max(1, b.count / cap)
        let target = within * within
        var best = Float.greatestFiniteMagnitude
        var i = 0
        while i < a.count {
            let p = positions[a[i]]
            var j = 0
            while j < b.count {
                let d = simd_distance_squared(p, positions[b[j]])
                if d < best { best = d }
                if best <= target { return within }   // the answer is yes; stop
                j += strideB
            }
            i += strideA
        }
        return best.squareRoot()
    }

    /// No tap to trust: the largest cluster, biased toward the scan centre.
    private static func centreBiasedCluster(_ parts: [[Int]], positions: [SIMD3<Float>],
                                            centroids: [SIMD3<Float>],
                                            centre: SIMD3<Float>) -> Int {
        guard let largest = parts.first else { return 0 }
        var best = 0
        var bestScore = -Float.infinity
        for (i, part) in parts.prefix(8).enumerated() where part.count >= largest.count / 5 {
            let size = Float(part.count) / Float(largest.count)
            let proximity = 1 / (1 + simd_distance(centroids[i], centre))
            let score = size * 0.7 + proximity * 0.3
            if score > bestScore { bestScore = score; best = i }
        }
        return best
    }

    /// Re-unites one subject that fragmented, growing outward from its seed
    /// cluster. A subject often breaks into several clusters (thin spots, gaps in
    /// coverage); two rules decide what joins it:
    ///
    ///   • NO LARGER than the seed cluster — the guard against swallowing a
    ///     different, comparably-sized object standing nearby ("it adds another
    ///     object than the one I scanned").
    ///   • WITHIN REACH of what has been kept so far, 1.8× its radius.
    ///
    /// There used to be a third: at least an eighth of the largest cluster. That
    /// is what cost a pair of steel-rimmed glasses 98% of its points — 21 945 in,
    /// `cluster 431` out. A thin rim is not one blob: it breaks into dozens of
    /// small components, and a floor tied to the LARGEST component excludes all of
    /// them by construction, the thinner the subject the more so. Size was never
    /// the signal that separates "my subject, in pieces" from "the thing behind
    /// it"; proximity is, and the no-larger rule already carries the anti-swallow
    /// guarantee.
    ///
    /// Growth is iterated so a chain of fragments — the temple arms reaching away
    /// from the lenses — re-unites instead of stopping at the first gap, with the
    /// size cap still measured against the ORIGINAL cluster so absorbing cannot
    /// snowball into eating a bigger neighbour. `absorbed` is shared across
    /// subjects, so a fragment is claimed once and no point is kept twice.
    private static func growSubject(seed: Int, parts: [[Int]], centroids: [SIMD3<Float>],
                                    positions: [SIMD3<Float>],
                                    absorbed: inout Set<Int>) -> [Int] {
        let seedPart = parts[seed]
        var keepIndices = seedPart
        var centre = centroids[seed]
        var radius: Float = 0
        for idx in seedPart { radius = max(radius, simd_distance(positions[idx], centre)) }
        for _ in 0..<4 {
            let reach = max(radius * 1.8, 0.12)
            var grew = false
            for (i, part) in parts.enumerated()
            where !absorbed.contains(i) && part.count <= seedPart.count
                && simd_distance(centroids[i], centre) <= reach {
                keepIndices.append(contentsOf: part)
                absorbed.insert(i)
                grew = true
            }
            guard grew else { break }
            var sum = SIMD3<Float>.zero
            for idx in keepIndices { sum += positions[idx] }
            centre = sum / Float(keepIndices.count)
            radius = 0
            for idx in keepIndices {
                radius = max(radius, simd_distance(positions[idx], centre))
            }
        }
        return keepIndices
    }

    // MARK: - Deterministic RNG (testable RANSAC)

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
