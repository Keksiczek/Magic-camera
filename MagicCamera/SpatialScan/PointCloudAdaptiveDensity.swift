//
//  PointCloudAdaptiveDensity.swift
//  Magic Camera
//
//  Curvature-aware thinning. A uniform voxel downsample throws away edge detail
//  and flat-wall points at the same rate; this keeps points where the surface
//  bends (edges, corners, fine relief) and sheds them where it's flat. Per-point
//  surface variation comes from local-neighbourhood PCA; a curvature-weighted
//  Poisson-disk pass then enforces a small spacing on sharp regions and a much
//  larger one on flat ones.
//
//  Pure value math (ARKit-free, off-main-thread friendly, unit-testable).
//

import Foundation
import simd

/// Per-point surface variation σ = λ₀ / (λ₀+λ₁+λ₂) in [0, 1/3]: ~0 on a plane,
/// rising toward 1/3 at corners. Uses the same spatial-hash k-NN + symmetric
/// 3×3 eigen-decomposition as the normal estimator.
enum PointCloudCurvature {
    static func estimate(_ cloud: PointCloud, neighbors k: Int = 12) -> [Float] {
        let n = cloud.count
        guard n >= 3, let box = cloud.boundingBox() else {
            return [Float](repeating: 0, count: n)
        }
        let extent = box.max - box.min
        let volume = max(extent.x, 0.01) * max(extent.y, 0.01) * max(extent.z, 0.01)
        let cell = max(cbrtf(volume / Float(n)) * 2, 0.005)
        let grid = HashGrid(points: cloud.positions, cell: cell)

        var curvature = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = cloud.positions[i]
            let idx = grid.nearest(to: p, in: cloud.positions, k: k)
            guard idx.count >= 3 else { continue }
            var mean = SIMD3<Float>.zero
            for j in idx { mean += cloud.positions[j] }
            mean /= Float(idx.count)
            var xx: Float = 0, xy: Float = 0, xz: Float = 0
            var yy: Float = 0, yz: Float = 0, zz: Float = 0
            for j in idx {
                let d = cloud.positions[j] - mean
                xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
                yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
            }
            let e = eigenvalues(xx: xx, xy: xy, xz: xz, yy: yy, yz: yz, zz: zz)
            let sum = e.0 + e.1 + e.2
            curvature[i] = sum > 1e-9 ? e.0 / sum : 0   // e.0 is the smallest
        }
        return curvature
    }

    /// Ascending eigenvalues of a symmetric 3×3 matrix via cyclic Jacobi.
    private static func eigenvalues(xx: Float, xy: Float, xz: Float,
                                    yy: Float, yz: Float, zz: Float) -> (Float, Float, Float) {
        var a = [[xx, xy, xz], [xy, yy, yz], [xz, yz, zz]]
        for _ in 0..<24 {
            var p = 0, q = 1
            var maxOff = abs(a[0][1])
            if abs(a[0][2]) > maxOff { maxOff = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > maxOff { maxOff = abs(a[1][2]); p = 1; q = 2 }
            if maxOff < 1e-9 { break }
            let app = a[p][p], aqq = a[q][q], apq = a[p][q]
            let diff = aqq - app
            let t: Float
            if abs(apq) < abs(diff) * 1e-12 {
                t = apq / diff
            } else {
                let phi = diff / (2 * apq)
                let denom = abs(phi) + (phi * phi + 1).squareRoot()
                t = (phi >= 0 ? 1 : -1) / denom
            }
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c
            a[p][p] = app - t * apq
            a[q][q] = aqq + t * apq
            a[p][q] = 0; a[q][p] = 0
            for r in 0..<3 where r != p && r != q {
                let arp = a[r][p], arq = a[r][q]
                a[r][p] = c * arp - s * arq; a[p][r] = a[r][p]
                a[r][q] = s * arp + c * arq; a[q][r] = a[r][q]
            }
        }
        let values = [a[0][0], a[1][1], a[2][2]].sorted()
        return (values[0], values[1], values[2])
    }

    /// Uniform spatial hash returning approximate k nearest within the 3×3×3
    /// block around a query.
    struct HashGrid {
        let cell: Float
        private var buckets: [SIMD3<Int32>: [Int]] = [:]

        init(points: [SIMD3<Float>], cell: Float) {
            self.cell = max(cell, 1e-4)
            buckets.reserveCapacity(points.count)
            for (i, p) in points.enumerated() { buckets[key(p), default: []].append(i) }
        }

        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }

        func nearest(to p: SIMD3<Float>, in points: [SIMD3<Float>], k: Int) -> [Int] {
            let base = key(p)
            var candidates: [(index: Int, d2: Float)] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let nk = SIMD3<Int32>(base.x &+ Int32(dx), base.y &+ Int32(dy), base.z &+ Int32(dz))
                        guard let bucket = buckets[nk] else { continue }
                        for idx in bucket {
                            candidates.append((idx, simd_distance_squared(points[idx], p)))
                        }
                    }
                }
            }
            candidates.sort { $0.d2 < $1.d2 }
            return candidates.prefix(k).map { $0.index }
        }
    }
}

enum PointCloudAdaptiveDownsampler {
    /// Curvature-weighted Poisson-disk thinning. `spacing` is the minimum
    /// distance kept on the sharpest regions; flat regions thin out to up to
    /// `flatFactor`× that. Points are placed sharpest-first so feature points
    /// claim their spot before flat ones. `sharpVariation` is the surface
    /// variation treated as fully sharp (≈ a crisp edge).
    static func downsample(_ cloud: PointCloud, curvatures: [Float],
                           spacing: Float, flatFactor: Float = 4,
                           sharpVariation: Float = 0.08) -> PointCloud {
        let n = cloud.count
        guard n > 0, curvatures.count == n, spacing > 0 else { return cloud }
        let rMin = spacing
        let rMax = spacing * max(flatFactor, 1)

        func radius(_ curvature: Float) -> Float {
            let t = min(max(curvature / max(sharpVariation, 1e-6), 0), 1)   // 0 flat … 1 sharp
            return rMax + (rMin - rMax) * t
        }

        // Place sharpest points first so features survive.
        let order = (0..<n).sorted { curvatures[$0] > curvatures[$1] }

        let cell = rMax
        var buckets: [SIMD3<Int32>: [(p: SIMD3<Float>, r: Float)]] = [:]
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }

        var out = PointCloud()
        out.reserveCapacity(n)
        for i in order {
            let p = cloud.positions[i]
            let r = radius(curvatures[i])
            let base = key(p)
            var tooClose = false
            search: for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let nk = SIMD3<Int32>(base.x &+ Int32(dx), base.y &+ Int32(dy), base.z &+ Int32(dz))
                        guard let bucket = buckets[nk] else { continue }
                        for kept in bucket {
                            // Symmetric: respect whichever disk is larger.
                            let limit = Swift.max(r, kept.r)
                            if simd_distance_squared(kept.p, p) < limit * limit {
                                tooClose = true
                                break search
                            }
                        }
                    }
                }
            }
            guard !tooClose else { continue }
            buckets[base, default: []].append((p, r))
            out.append(position: p, color: cloud.colors[i], confidence: cloud.confidences[i])
        }
        return out
    }
}
