//
//  AdaptiveOctree.swift
//  Magic Camera
//
//  Foundation for variable-resolution ("adaptive") surface reconstruction. The
//  current reconstructor meshes on a single uniform lattice, so one resolution has
//  to serve both a room's blank walls and the detailed objects in it: fine enough
//  for the objects over-tessellates (and, once decimated back down, blurs) the
//  walls; coarse enough for the walls loses the objects. An adaptive octree breaks
//  that tie — a cell keeps subdividing while its points still curve away from a
//  plane (surface variation above `curvatureThreshold`) and stops once the patch is
//  locally flat, so a wall settles into a few big leaves while a curved / detailed
//  object subdivides down toward `minCell`. Each leaf then carries the resolution
//  its geometry actually needs.
//
//  This module only produces the PARTITION (the "where to be fine vs coarse"
//  decision). The adaptive mesher that turns leaves into triangles, and the
//  area-proportional texture atlas that keeps big flat leaves sharp, build on top.
//  Not yet wired into the live pipeline.
//
//  Pure value math, off-main, unit-testable. Reuses CaptureDensity's surface
//  variation for the curvature test.
//

import simd

enum AdaptiveOctree {
    struct Leaf {
        var min: SIMD3<Float>
        /// Edge length of this cubic leaf — its target reconstruction resolution.
        var size: Float
        /// Indices into the source cloud that fall in this leaf.
        var pointIndices: [Int32]
        var center: SIMD3<Float> { min + SIMD3<Float>(repeating: size * 0.5) }
    }

    struct Result {
        var leaves: [Leaf]
        /// Root cell minimum corner — the shared origin every leaf's lattice
        /// coordinate is measured from (the mesher maps leaves onto it).
        var rootMin: SIMD3<Float>
        var minLeafSize: Float
        var maxLeafSize: Float
        /// Leaves at the finer half of the size range (curved / detailed regions).
        var fineCount: Int
        /// One-line diagnostics summary.
        var summary: String {
            let lo = Int((minLeafSize * 1000).rounded()), hi = Int((maxLeafSize * 1000).rounded())
            return "leaves \(leaves.count) · \(lo)–\(hi)mm · fine \(fineCount)"
        }
    }

    /// Partitions `cloud` into an adaptive octree. A cell always subdivides while it
    /// is coarser than `maxCell`; between `maxCell` and `minCell` it subdivides only
    /// where the points deviate from their best-fit plane by more than
    /// `flatnessTolerance` (curved / detailed → finer), and it stops at `minCell` or
    /// when a cell holds too few points.
    ///
    /// The flatness test is an ABSOLUTE plane residual (metres), not a scale-invariant
    /// ratio: LiDAR depth noise is a fixed ~1–2 cm whatever the cell size, so a ratio
    /// metric read a noisy flat wall as "curved" at small cells and never coarsened it
    /// (`fine 100568/100569`). A residual below the noise floor means flat at any scale,
    /// so the wall collapses to a few big leaves while real > tolerance relief still
    /// subdivides down toward `minCell`.
    static func partition(_ cloud: PointCloud, minCell: Float, maxCell: Float,
                          flatnessTolerance: Float = 0.02, minPoints: Int = 8) -> Result {
        let n = cloud.count
        guard n >= minPoints, minCell > 0, maxCell >= minCell,
              let box = boundingBox(cloud.positions) else {
            return Result(leaves: [], rootMin: .zero, minLeafSize: 0, maxLeafSize: 0, fineCount: 0)
        }
        // Cube the root so cells stay cubic through the halving.
        let extent = box.max - box.min
        let rootSize = max(extent.x, extent.y, extent.z, minCell)

        var leaves: [Leaf] = []
        // Work stack of (cell min, size, point indices). Root owns every point.
        var stack: [(min: SIMD3<Float>, size: Float, idx: [Int32])] = [
            (box.min, rootSize, Array(0..<Int32(n)))
        ]
        while let cell = stack.popLast() {
            // Sparse or already fine → a leaf.
            if cell.idx.count < minPoints || cell.size <= minCell {
                if !cell.idx.isEmpty {
                    leaves.append(Leaf(min: cell.min, size: cell.size, pointIndices: cell.idx))
                }
                continue
            }
            // Above the coarse bound → always split. Within [minCell, maxCell] →
            // split only if the region deviates from a plane by more than the noise
            // floor (real relief), else make it a leaf (a flat wall, at any scale).
            if cell.size <= maxCell,
               planeResidual(cell.idx, cloud.positions) <= flatnessTolerance {
                leaves.append(Leaf(min: cell.min, size: cell.size, pointIndices: cell.idx))
                continue
            }
            // Subdivide into 8 octants, partitioning the point indices by octant.
            let half = cell.size * 0.5
            let mid = cell.min + SIMD3<Float>(repeating: half)
            var buckets = [[Int32]](repeating: [], count: 8)
            for i in cell.idx {
                let p = cloud.positions[Int(i)]
                let octant = (p.x >= mid.x ? 1 : 0) | (p.y >= mid.y ? 2 : 0) | (p.z >= mid.z ? 4 : 0)
                buckets[octant].append(i)
            }
            for octant in 0..<8 where !buckets[octant].isEmpty {
                let offset = SIMD3<Float>(octant & 1 == 0 ? 0 : half,
                                          octant & 2 == 0 ? 0 : half,
                                          octant & 4 == 0 ? 0 : half)
                stack.append((cell.min + offset, half, buckets[octant]))
            }
        }

        guard !leaves.isEmpty else {
            return Result(leaves: [], rootMin: box.min, minLeafSize: 0, maxLeafSize: 0, fineCount: 0)
        }
        let sizes = leaves.map(\.size)
        let lo = sizes.min() ?? 0, hi = sizes.max() ?? 0
        let mid = (lo + hi) * 0.5
        let fine = leaves.reduce(0) { $0 + ($1.size <= mid ? 1 : 0) }
        return Result(leaves: leaves, rootMin: box.min, minLeafSize: lo, maxLeafSize: hi, fineCount: fine)
    }

    private static func boundingBox(_ positions: [SIMD3<Float>])
        -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = positions.first else { return nil }
        var lo = first, hi = first
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    /// RMS distance of `pts` from their best-fit plane (metres) — how far the patch
    /// bends away from flat. The plane normal is the smallest-eigenvector of the
    /// covariance, found by deflating the two dominant in-plane axes (stable even on a
    /// perfectly flat patch). A patch too small or collinear to judge reads as flat.
    private static func planeResidual(_ indices: [Int32], _ positions: [SIMD3<Float>]) -> Float {
        let n = indices.count
        guard n >= 4 else { return 0 }
        var centroid = SIMD3<Float>.zero
        for i in indices { centroid += positions[Int(i)] }
        centroid /= Float(n)
        var cov = simd_float3x3(0)
        for i in indices {
            let d = positions[Int(i)] - centroid
            cov.columns.0 += d * d.x; cov.columns.1 += d * d.y; cov.columns.2 += d * d.z
        }
        let e1 = dominantEigenvector(cov, seed: SIMD3<Float>(1, 0, 0))
        let lambda1 = simd_dot(e1, cov * e1)
        var deflated = cov
        deflated.columns.0 -= e1 * (lambda1 * e1.x)
        deflated.columns.1 -= e1 * (lambda1 * e1.y)
        deflated.columns.2 -= e1 * (lambda1 * e1.z)
        let e2 = dominantEigenvector(deflated, seed: SIMD3<Float>(0, 1, 0))
        let normalRaw = simd_cross(e1, e2)
        let len = simd_length(normalRaw)
        guard len > 1e-9 else { return 0 }   // collinear → treat as flat
        let normal = normalRaw / len
        var sumSq: Float = 0
        for i in indices { let r = simd_dot(positions[Int(i)] - centroid, normal); sumSq += r * r }
        return (sumSq / Float(n)).squareRoot()
    }

    private static func dominantEigenvector(_ m: simd_float3x3, seed: SIMD3<Float>) -> SIMD3<Float> {
        var v = seed
        for _ in 0..<24 {
            let next = m * v
            let length = simd_length(next)
            if length < 1e-12 { return v }
            v = next / length
        }
        return v
    }
}
