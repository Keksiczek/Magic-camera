//
//  SmoothSurfaceReconstructor.swift
//  Magic Camera
//
//  Poisson-style smooth surface reconstruction from an oriented point cloud:
//
//    1. Estimate per-point normals (PCA) when not supplied.
//    2. Build a signed implicit field on a sparse lattice — at each corner the
//       field is the weighted average of dot(x − pᵢ, nᵢ) over nearby points
//       (Hoppe-style signed distance, Gaussian-weighted; the same local plane
//       fit that screened Poisson regularises globally).
//    3. Polygonise the narrow band with marching cubes at iso-level 0.
//
//  Produces a smooth, organic surface (no voxel blockiness) that follows the
//  scanned shape. Pure value math — ARKit-free, off-main-thread friendly.
//

import simd

enum SmoothSurfaceReconstructor {
    /// Reconstructs a smooth surface, or nil when the cloud is too sparse.
    /// `resolution` is the approximate lattice size along the longest axis;
    /// `normals` are reused when supplied (must be index-aligned to the cloud).
    static func reconstruct(_ cloud: PointCloud,
                            resolution: Int = 96,
                            normals: [SIMD3<Float>]? = nil) -> MeshData? {
        guard cloud.count >= 100, let box = cloud.boundingBox() else { return nil }
        let extent = box.max - box.min
        let maxExtent = max(max(extent.x, extent.y), extent.z)
        guard maxExtent > 0 else { return nil }

        let cellSize = max(maxExtent / Float(max(resolution, 16)), 0.002)
        // Pad so the surface band never touches the lattice boundary.
        let origin = box.min - SIMD3<Float>(repeating: cellSize * 2)

        // Decimate to the field's working resolution first: points packed
        // denser than half a lattice cell add neighbour-search cost but no
        // surface information. Without this, room-scale clouds (1.5 M points,
        // hundreds per support radius) push the field evaluation into
        // billions of kernel taps — the "Fusion never finishes" hang.
        let dedupCell = cellSize * 0.5
        let suppliedNormals: [SIMD3<Float>]? = (normals?.count == cloud.count) ? normals : nil
        var seen = Set<SIMD3<Int32>>()
        seen.reserveCapacity(min(cloud.count, 600_000))
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(min(cloud.count, 600_000))
        var pointNormals: [SIMD3<Float>] = []
        if suppliedNormals != nil { pointNormals.reserveCapacity(min(cloud.count, 600_000)) }
        for i in 0..<cloud.count {
            let p = cloud.positions[i]
            let scaled = p / dedupCell
            let key = SIMD3<Int32>(Int32(scaled.x.rounded(.down)),
                                   Int32(scaled.y.rounded(.down)),
                                   Int32(scaled.z.rounded(.down)))
            guard seen.insert(key).inserted else { continue }
            positions.append(p)
            if let suppliedNormals { pointNormals.append(suppliedNormals[i]) }
        }
        if suppliedNormals == nil {
            var decimated = PointCloud()
            decimated.reserveCapacity(positions.count)
            for p in positions {
                decimated.append(position: p, color: SIMD3<Float>(repeating: 0.5), confidence: 1)
            }
            pointNormals = PointCloudNormals.estimate(decimated)
        }
        guard positions.count >= 100, pointNormals.count == positions.count else { return nil }

        // Spatial hash of points on the field's support radius.
        let support = cellSize * 2.2
        let grid = SupportGrid(points: positions, cell: support)

        // Field samples are evaluated lazily per lattice corner and cached.
        var fieldCache: [SIMD3<Int32>: Float] = [:]
        fieldCache.reserveCapacity(positions.count * 2)

        /// Gaussian-weighted signed distance to the local plane of nearby points;
        /// nil when the corner has no points within the support radius.
        func field(at corner: SIMD3<Int32>) -> Float? {
            if let cached = fieldCache[corner] {
                return cached.isFinite ? cached : nil
            }
            let x = origin + SIMD3<Float>(Float(corner.x), Float(corner.y), Float(corner.z)) * cellSize
            var weightSum: Float = 0
            var valueSum: Float = 0
            // The 3×3×3 hash search only guarantees neighbours within one cell
            // (= support), so the kernel is truncated at that radius too.
            let inv2s2 = 1 / (2 * support * support)
            grid.forEachNeighbor(of: x) { index, d2 in
                guard d2 < support * support else { return }
                let w = expf(-d2 * inv2s2)
                weightSum += w
                valueSum += w * simd_dot(x - positions[index], pointNormals[index])
            }
            guard weightSum > 1e-6 else {
                fieldCache[corner] = .infinity   // sentinel: undefined
                return nil
            }
            let v = valueSum / weightSum
            fieldCache[corner] = v
            return v
        }

        // Narrow band: every lattice cell within 1 cell of any point.
        var band = Set<SIMD3<Int32>>()
        band.reserveCapacity(positions.count)
        for p in positions {
            let s = (p - origin) / cellSize
            let base = SIMD3<Int32>(Int32(s.x.rounded(.down)),
                                    Int32(s.y.rounded(.down)),
                                    Int32(s.z.rounded(.down)))
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        band.insert(base &+ SIMD3<Int32>(dx, dy, dz))
                    }
                }
            }
        }
        guard !band.isEmpty, band.count < 4_000_000 else { return nil }

        // Sample corners and emit complete cells for marching cubes.
        var cells: [MarchingCubes.Cell] = []
        cells.reserveCapacity(band.count / 2)
        for cellIndex in band {
            var values = [Float](repeating: 0, count: 8)
            var complete = true
            for (i, offset) in MarchingCubes.cornerOffsets.enumerated() {
                guard let v = field(at: cellIndex &+ offset) else { complete = false; break }
                values[i] = v
            }
            guard complete else { continue }
            cells.append(MarchingCubes.Cell(
                base: cellIndex,
                values: (values[0], values[1], values[2], values[3],
                         values[4], values[5], values[6], values[7])))
        }
        guard !cells.isEmpty else { return nil }

        return MarchingCubes.mesh(cells: cells, origin: origin, cellSize: cellSize)
    }

    /// Uniform spatial hash that streams neighbours in the 3×3×3 block around a
    /// query point (cell size = field support radius).
    private struct SupportGrid {
        let cell: Float
        private let points: [SIMD3<Float>]
        private var buckets: [SIMD3<Int32>: [Int]] = [:]

        init(points: [SIMD3<Float>], cell: Float) {
            self.cell = max(cell, 1e-4)
            self.points = points
            buckets.reserveCapacity(points.count)
            for (i, p) in points.enumerated() { buckets[key(p), default: []].append(i) }
        }

        private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }

        /// Calls `body(index, squaredDistance)` for every point in the 3×3×3
        /// block of cells around `p`.
        func forEachNeighbor(of p: SIMD3<Float>, _ body: (Int, Float) -> Void) {
            let base = key(p)
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        guard let bucket = buckets[base &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                        for index in bucket {
                            body(index, simd_distance_squared(points[index], p))
                        }
                    }
                }
            }
        }
    }
}
