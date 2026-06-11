//
//  PointCloudSampler.swift
//  Magic Camera
//
//  Poisson-disk (dart-throwing) downsampling: visits points in a deterministic
//  shuffled order and keeps one only when no already-kept point lies within the
//  disk radius. Unlike stride downsampling this preserves detail uniformly
//  (blue-noise spacing) — exactly what ball-pivoting wants as input. Pure value
//  math — ARKit-free and unit-testable.
//

import simd

enum PointCloudSampler {
    /// Downsamples to roughly `targetCount` points with even spacing. Returns
    /// the cloud unchanged when it is already small enough.
    static func poissonDisk(_ cloud: PointCloud, targetCount: Int,
                            seed: UInt64 = 0x1234_5678) -> PointCloud {
        let n = cloud.count
        guard targetCount > 0, n > targetCount else { return cloud }
        guard let spacing = BallPivotingMesher.meanSpacing(cloud.positions) else {
            return cloud.downsampled(maxCount: targetCount)
        }
        // Scan points sample a 2D surface: density scales with 1/r², so the
        // disk radius that yields ~targetCount points is spacing·√(n/target).
        let radius = max(spacing * (Float(n) / Float(targetCount)).squareRoot(), spacing)
        let radius2 = radius * radius

        // Deterministic shuffled visit order (Fisher–Yates with SplitMix64).
        var order = Array(0..<n)
        var state = seed
        for i in stride(from: n - 1, to: 0, by: -1) {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let j = Int(z % UInt64(i + 1))
            order.swapAt(i, j)
        }

        // Accepted points live in a hash grid with cell = radius, so the
        // 3×3×3 neighbourhood fully covers the rejection disk.
        var buckets: [SIMD3<Int32>: [Int]] = [:]
        buckets.reserveCapacity(targetCount)
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / radius).rounded(.down)),
                         Int32((p.y / radius).rounded(.down)),
                         Int32((p.z / radius).rounded(.down)))
        }

        var out = PointCloud()
        out.reserveCapacity(targetCount + targetCount / 4)
        for index in order {
            let p = cloud.positions[index]
            let base = key(p)
            var blocked = false
            outer: for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        guard let bucket = buckets[base &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                        for kept in bucket
                        where simd_distance_squared(out.positions[kept], p) < radius2 {
                            blocked = true
                            break outer
                        }
                    }
                }
            }
            if blocked { continue }
            buckets[base, default: []].append(out.count)
            out.append(position: p, color: cloud.colors[index],
                       confidence: cloud.confidences[index])
        }
        return out.isEmpty ? cloud.downsampled(maxCount: targetCount) : out
    }
}
