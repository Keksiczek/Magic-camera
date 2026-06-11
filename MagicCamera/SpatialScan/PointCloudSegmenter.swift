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
    }

    // MARK: - RANSAC plane

    /// Detects the dominant plane, or nil when no plane holds at least
    /// `minInlierFraction` of the points. `tolerance` defaults to ~1.5× the
    /// mean point spacing.
    static func detectDominantPlane(_ cloud: PointCloud,
                                    iterations: Int = 96,
                                    tolerance: Float? = nil,
                                    minInlierFraction: Float = 0.12,
                                    seed: UInt64 = 0x5EED) -> Plane? {
        let n = cloud.count
        guard n >= 50 else { return nil }
        let positions = cloud.positions
        let eps = tolerance ?? max((BallPivotingMesher.meanSpacing(positions) ?? 0.01) * 1.5, 0.008)

        var rng = SplitMix64(seed: seed)
        var best: Plane?
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
            if inliers > (best?.inlierCount ?? 0) {
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

    // MARK: - One-tap isolation

    /// Strips the dominant support plane and keeps the best object cluster —
    /// the largest one, biased toward the centre of the scanned volume (the
    /// subject is normally what the user orbited around, not wall fragments).
    static func isolateMainSubject(_ cloud: PointCloud) -> IsolationResult? {
        guard cloud.count >= 100 else { return nil }

        var working = cloud
        var removedPlane = 0
        if let plane = detectDominantPlane(cloud) {
            let stripped = removingPlane(cloud, plane: plane)
            // Only strip when something meaningful is left.
            if stripped.count >= 50 {
                removedPlane = cloud.count - stripped.count
                working = stripped
            }
        }

        let parts = clusters(working)
        guard let largest = parts.first, largest.count >= 30 else { return nil }

        let center = working.centroid()
        var bestIndex = 0
        var bestScore = -Float.infinity
        for (i, part) in parts.prefix(8).enumerated() where part.count >= largest.count / 5 {
            var sum = SIMD3<Float>.zero
            for idx in part { sum += working.positions[idx] }
            let clusterCenter = sum / Float(part.count)
            // Larger and closer to the scan centre is better.
            let size = Float(part.count) / Float(largest.count)
            let proximity = 1 / (1 + simd_distance(clusterCenter, center))
            let score = size * 0.7 + proximity * 0.3
            if score > bestScore { bestScore = score; bestIndex = i }
        }

        let kept = subset(working, indices: parts[bestIndex])
        return IsolationResult(cloud: kept,
                               removedPlanePoints: removedPlane,
                               clusterCount: parts.count,
                               keptPoints: kept.count)
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
