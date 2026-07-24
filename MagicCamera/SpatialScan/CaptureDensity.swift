//
//  CaptureDensity.swift
//  Magic Camera
//
//  Content-adaptive capture density: tells the recorder *what* it's looking at so
//  it can spend points where the geometry is. A room scan should keep fine detail
//  on the objects in it but not waste its point budget on blank walls — yet you
//  can't just scan the whole room at object resolution (far too many points).
//
//  The signal is local surface variation σ = λ0 / (λ0 + λ1 + λ2), the smallest
//  eigenvalue of a neighbourhood's covariance over the sum of all three (Pauly's
//  surface-variation curvature estimate). A flat wall — even a LiDAR-noisy one —
//  keeps σ near 0 because the depth-noise eigenvalue stays tiny next to the wall's
//  in-plane spread; an object's curvature, a corner, or relief lifts σ. The
//  recorder then coarsens the voxel lattice on low-σ (flat) points and keeps it
//  fine on high-σ (structured) ones.
//
//  Computed per occupied cell (not per point) so it stays cheap on the capture
//  hot path. Pure value math, off-main, unit-testable.
//

import simd

enum CaptureDensity {
    /// Per-point surface variation σ ∈ [0, 1/3] (0 = flat). Points are grouped into
    /// a `cellSize` grid; each occupied cell's σ is computed once from its 3×3×3
    /// neighbourhood and shared by its members. Sparse cells (too few neighbours to
    /// fit a plane) return 1 — treated as detail, so thin/edge geometry stays fine.
    static func surfaceVariation(_ positions: [SIMD3<Float>], cellSize: Float) -> [Float] {
        let n = positions.count
        guard n >= 8, cellSize > 0 else { return [Float](repeating: 1, count: n) }

        var grid = [SIMD3<Int32>: [Int32]](minimumCapacity: n / 2)
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            let s = p / cellSize
            return SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
        }
        for i in 0..<n { grid[key(positions[i]), default: []].append(Int32(i)) }

        var out = [Float](repeating: 1, count: n)
        let minNeighbours = 6
        for (cell, members) in grid {
            var neighbours: [SIMD3<Float>] = []
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                if let bucket = grid[cell &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))] {
                    for j in bucket { neighbours.append(positions[Int(j)]) }
                }
            } } }
            let sigma = neighbours.count >= minNeighbours ? variation(neighbours) : 1
            for j in members { out[Int(j)] = sigma }
        }
        return out
    }

    /// σ = λ0 / (λ0+λ1+λ2). Trace gives the eigenvalue sum directly; λ2 (dominant)
    /// and λ1 (after deflation) come from power iteration, λ0 = trace − λ1 − λ2.
    static func variation(_ pts: [SIMD3<Float>]) -> Float {
        guard pts.count >= 3 else { return 1 }
        var centroid = SIMD3<Float>.zero
        for p in pts { centroid += p }
        centroid /= Float(pts.count)
        var c = simd_float3x3(0)
        for p in pts {
            let d = p - centroid
            c.columns.0 += d * d.x
            c.columns.1 += d * d.y
            c.columns.2 += d * d.z
        }
        let trace = c.columns.0.x + c.columns.1.y + c.columns.2.z
        guard trace > 1e-12 else { return 0 }
        let e2 = dominantEigenvector(c, seed: SIMD3<Float>(1, 0, 0))
        let l2 = simd_dot(e2, c * e2)
        var deflated = c
        deflated.columns.0 -= e2 * (l2 * e2.x)
        deflated.columns.1 -= e2 * (l2 * e2.y)
        deflated.columns.2 -= e2 * (l2 * e2.z)
        let e1 = dominantEigenvector(deflated, seed: SIMD3<Float>(0, 1, 0))
        let l1 = simd_dot(e1, c * e1)
        let l0 = max(trace - l1 - l2, 0)
        return l0 / trace
    }

    private static func dominantEigenvector(_ m: simd_float3x3, seed: SIMD3<Float>) -> SIMD3<Float> {
        var v = seed
        for _ in 0..<16 {
            let next = m * v
            let len = simd_length(next)
            if len < 1e-12 { return v }
            v = next / len
        }
        return v
    }
}
