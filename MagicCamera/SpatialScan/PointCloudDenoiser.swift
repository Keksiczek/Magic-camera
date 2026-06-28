//
//  PointCloudDenoiser.swift
//  Magic Camera
//
//  Statistical outlier removal: for each point, the mean distance to its k
//  nearest neighbours is computed; points whose mean distance exceeds
//  globalMean + stdRatio · globalStd are dropped. Cleans isolated specks and
//  floaters from a scan. Pure value-type math, off-main-thread friendly.
//

import Foundation
import simd

enum PointCloudDenoiser {
    /// Returns a cleaned copy. `neighbors` is the k used per point; a larger
    /// `stdRatio` keeps more points (less aggressive).
    static func removeOutliers(_ cloud: PointCloud,
                               neighbors k: Int = 8,
                               stdRatio: Float = 1.5) -> PointCloud {
        let n = cloud.count
        guard n > k + 4, let box = cloud.boundingBox() else { return cloud }

        // Cell ≈ average point spacing so a 3×3×3 search yields enough neighbours.
        let extent = box.max - box.min
        let volume = max(extent.x, 0.01) * max(extent.y, 0.01) * max(extent.z, 0.01)
        let cell = max(cbrtf(volume / Float(n)) * 2, 0.005)
        let grid = HashGrid(points: cloud.positions, cell: cell)

        // Points with no neighbours at all report `.infinity` — they are isolated
        // floaters and always outliers. Keep them out of the mean/std (otherwise the
        // threshold blows up to infinity and nothing gets filtered) and drop them.
        var meanDistances = [Float](repeating: 0, count: n)
        var sum: Float = 0
        var finiteCount = 0
        for i in 0..<n {
            let d = grid.meanNeighborDistance(of: cloud.positions[i], in: cloud.positions, k: k)
            meanDistances[i] = d
            if d.isFinite { sum += d; finiteCount += 1 }
        }
        guard finiteCount > 0 else { return cloud }
        let mean = sum / Float(finiteCount)
        var variance: Float = 0
        for d in meanDistances where d.isFinite { let dd = d - mean; variance += dd * dd }
        let std = (variance / Float(finiteCount)).squareRoot()
        let threshold = mean + stdRatio * std

        var out = PointCloud()
        for i in 0..<n where meanDistances[i].isFinite && meanDistances[i] <= threshold {
            out.append(position: cloud.positions[i], color: cloud.colors[i],
                       confidence: cloud.confidences[i])
        }
        // Never return an empty cloud (e.g. degenerate input).
        return out.isEmpty ? cloud : out
    }

    private struct HashGrid {
        let cell: Float
        private var buckets: [SIMD3<Int32>: [Int]] = [:]

        init(points: [SIMD3<Float>], cell: Float) {
            self.cell = max(cell, 1e-4)
            buckets.reserveCapacity(points.count)
            for (i, p) in points.enumerated() { buckets[key(p), default: []].append(i) }
        }

        private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }

        /// Mean distance to the k nearest neighbours found in the 3×3×3 block.
        ///
        /// Single pass keeping only the k smallest squared distances in a stack
        /// buffer (kept sorted ascending) — no per-point heap allocation and no
        /// full sort of every candidate. On a dense scan each 27-cell query can
        /// gather several hundred neighbours; collecting them all into a growing
        /// array and `sort()`-ing it per point (× millions of points) is what
        /// pegged a core for ~90 s in `removeOutliers`. The k smallest is the
        /// same set the old `sort().prefix(k)` produced, so the result is
        /// unchanged — only the work to find it is bounded to O(neighbours · k)
        /// with k = 8 and an O(1) reject once the buffer is full.
        func meanNeighborDistance(of p: SIMD3<Float>, in points: [SIMD3<Float>], k: Int) -> Float {
            guard k > 0 else { return .infinity }
            let base = key(p)
            return withUnsafeTemporaryAllocation(of: Float.self, capacity: k) { buf in
                var count = 0   // filled slots in `buf`, kept ascending
                for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 {
                            let nk = SIMD3<Int32>(base.x &+ Int32(dx), base.y &+ Int32(dy), base.z &+ Int32(dz))
                            guard let bucket = buckets[nk] else { continue }
                            for idx in bucket {
                                let d2 = simd_distance_squared(points[idx], p)
                                guard d2 > 1e-9 else { continue }
                                if count < k {
                                    var j = count
                                    while j > 0, buf[j - 1] > d2 { buf[j] = buf[j - 1]; j -= 1 }
                                    buf[j] = d2
                                    count += 1
                                } else if d2 < buf[k - 1] {
                                    var j = k - 1
                                    while j > 0, buf[j - 1] > d2 { buf[j] = buf[j - 1]; j -= 1 }
                                    buf[j] = d2
                                }
                            }
                        }
                    }
                }
                guard count > 0 else { return .infinity }
                var sum: Float = 0
                for i in 0..<count { sum += buf[i].squareRoot() }
                return sum / Float(count)
            }
        }
    }
}
