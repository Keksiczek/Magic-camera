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
    /// where the local surface variation exceeds `curvatureThreshold` (curved →
    /// finer), and it stops at `minCell` or when a cell holds too few points.
    static func partition(_ cloud: PointCloud, minCell: Float, maxCell: Float,
                          curvatureThreshold: Float = 0.04, minPoints: Int = 8) -> Result {
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
            // split only if the region is still curving away from a plane.
            if cell.size <= maxCell {
                let pts = cell.idx.map { cloud.positions[Int($0)] }
                if CaptureDensity.variation(pts) <= curvatureThreshold {
                    leaves.append(Leaf(min: cell.min, size: cell.size, pointIndices: cell.idx))
                    continue
                }
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
}
