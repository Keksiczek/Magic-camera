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
    ///
    /// `adaptiveSupport` makes the lattice survive uneven point density: a room's
    /// far walls run 2-3× sparser than the mean spacing the lattice is sized from,
    /// so their cells either miss the ±1 narrow band entirely or lose corners to
    /// the truncated field support — marching cubes skips them and the surface
    /// comes out riddled with confetti holes. With the flag on, sparse points seed
    /// a proportionally wider band and corners with an empty base support retry at
    /// 2-3× the radius (wider Gaussian → locally smoother, but SOLID), while dense
    /// regions keep the exact base behaviour — fine detail where the data supports
    /// it, on one lattice, with no cross-resolution seams. Genuine voids (windows —
    /// LiDAR sees nothing through glass) stay open: the band never reaches beyond
    /// ~3 cells of a real point.
    static func reconstruct(_ cloud: PointCloud,
                            resolution: Int = 96,
                            normals: [SIMD3<Float>]? = nil,
                            adaptiveSupport: Bool = false) -> MeshData? {
        guard cloud.count >= 100, let box = cloud.boundingBox() else { return nil }
        let extent = box.max - box.min
        let maxExtent = max(max(extent.x, extent.y), extent.z)
        guard maxExtent > 0 else { return nil }

        // 1.5 mm floor (binds only for small subjects) lets a dense Object-mode
        // capture resolve finer features; room-scale scans sit well above it.
        let cellSize = max(maxExtent / Float(max(resolution, 16)), 0.0015)
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

        // Adaptive fallback for corners the base support leaves empty (sparse
        // regions only — dense corners resolve above and never reach here). The
        // Gaussian widens with the search radius so the sparse points found
        // actually carry weight; capped at 3× so a genuine void (a window) still
        // reads undefined and stays a hole.
        var expandedCache: [SIMD3<Int32>: Float] = [:]
        func expandedField(at corner: SIMD3<Int32>) -> Float? {
            if let cached = expandedCache[corner] {
                return cached.isFinite ? cached : nil
            }
            let x = origin + SIMD3<Float>(Float(corner.x), Float(corner.y), Float(corner.z)) * cellSize
            var value = Float.infinity
            var level: Int32 = 2
            while level <= 3 {
                let radius = support * Float(level)
                let inv2s2 = 1 / (2 * radius * radius)
                var weightSum: Float = 0
                var valueSum: Float = 0
                grid.forEachNeighbor(of: x, radiusCells: level) { index, d2 in
                    guard d2 < radius * radius else { return }
                    let w = expf(-d2 * inv2s2)
                    weightSum += w
                    valueSum += w * simd_dot(x - positions[index], pointNormals[index])
                }
                if weightSum > 1e-6 { value = valueSum / weightSum; break }
                level += 1
            }
            expandedCache[corner] = value
            return value.isFinite ? value : nil
        }

        // Narrow band: every lattice cell within reach of a point. The reach is 1
        // (the classic narrow band) except on the adaptive path, where a point in
        // a sparse neighbourhood widens it so cells spanning the local point gaps
        // still get meshed. The local spacing estimate is O(1) per point: a flat
        // surface crossing the point's own hash bucket (side = support) leaves
        // ≈ (support / spacing)² points in it.
        var band = Set<SIMD3<Int32>>()
        band.reserveCapacity(positions.count)
        for p in positions {
            var reach: Int32 = 1
            if adaptiveSupport {
                let inBucket = grid.countInBucket(of: p)
                let localSpacing = support / sqrtf(Float(max(inBucket, 1)))
                reach = Int32(min(max((localSpacing / cellSize).rounded(.up), 1), 3))
            }
            let s = (p - origin) / cellSize
            let base = SIMD3<Int32>(Int32(s.x.rounded(.down)),
                                    Int32(s.y.rounded(.down)),
                                    Int32(s.z.rounded(.down)))
            for dz in -reach...reach {
                for dy in -reach...reach {
                    for dx in -reach...reach {
                        band.insert(base &+ SIMD3<Int32>(dx, dy, dz))
                    }
                }
            }
        }
        guard !band.isEmpty, band.count < 4_000_000 else { return nil }

        // GPU acceleration: the per-corner field is the O(corners × neighbours)
        // hot loop. Gather the unique corners the band needs and evaluate them in
        // one GPU batch; fall back to the lazy CPU `field` when the GPU is
        // unavailable or a cheap sample disagrees with the CPU reference.
        var cornerList: [SIMD3<Int32>] = []
        var cornerSlot: [SIMD3<Int32>: Int] = [:]
        cornerSlot.reserveCapacity(band.count)
        for cell in band {
            for offset in MarchingCubes.cornerOffsets {
                let corner = cell &+ offset
                if cornerSlot[corner] == nil {
                    cornerSlot[corner] = cornerList.count
                    cornerList.append(corner)
                }
            }
        }
        let gpuField = Self.gpuField(corners: cornerList, origin: origin, cellSize: cellSize,
                                     support: support, positions: positions,
                                     normals: pointNormals, cpuReference: field)

        /// Unified corner sample: GPU result when trusted, else the lazy CPU
        /// field; on the adaptive path an undefined base sample (GPU or CPU —
        /// both evaluate the base support) falls through to the expanded field.
        func sample(_ corner: SIMD3<Int32>) -> Float? {
            if let gpuField, let slot = cornerSlot[corner] {
                let v = gpuField[slot]
                if v.isFinite { return v }
            } else if let v = field(at: corner) {
                return v
            }
            return adaptiveSupport ? expandedField(at: corner) : nil
        }

        // Sample corners and emit complete cells for marching cubes.
        var cells: [MarchingCubes.Cell] = []
        cells.reserveCapacity(band.count / 2)
        for cellIndex in band {
            var values = [Float](repeating: 0, count: 8)
            var complete = true
            for (i, offset) in MarchingCubes.cornerOffsets.enumerated() {
                guard let v = sample(cellIndex &+ offset) else { complete = false; break }
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

    /// Batch GPU evaluation of the signed field, gated by a CPU spot-check.
    /// Returns nil (→ caller uses the lazy CPU field) when the GPU path is
    /// unavailable or a sampled corner disagrees with the CPU reference — so a
    /// sign/indexing slip in the kernel can never ship a wrong surface.
    private static func gpuField(corners: [SIMD3<Int32>], origin: SIMD3<Float>,
                                 cellSize: Float, support: Float,
                                 positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                                 cpuReference: (SIMD3<Int32>) -> Float?) -> [Float]? {
        guard corners.count >= 8 else { return nil }   // too few to be worth the upload
        let cornerWorld = corners.map {
            origin + SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) * cellSize
        }
        guard let field = GPUPointProcessor.signedField(corners: cornerWorld, points: positions,
                                                        normals: normals, support: support),
              field.count == corners.count else { return nil }
        // Correctness gate: sample ~64 corners against the CPU field. A sign or
        // indexing slip in the kernel surfaces here and we keep the CPU result.
        let step = max(1, corners.count / 64)
        var i = 0
        while i < corners.count {
            let gpu = field[i]
            let cpu = cpuReference(corners[i])
            if gpu.isFinite != (cpu != nil) { return nil }
            if let cpu, gpu.isFinite, abs(gpu - cpu) > max(1e-4, 0.02 * abs(cpu)) { return nil }
            i += step
        }
        return field
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

        /// Number of points sharing `p`'s own hash bucket — an O(1) local
        /// density probe (bucket side = the field support radius).
        func countInBucket(of p: SIMD3<Float>) -> Int {
            buckets[key(p)]?.count ?? 0
        }

        /// Calls `body(index, squaredDistance)` for every point in the 3×3×3
        /// block of cells around `p`.
        func forEachNeighbor(of p: SIMD3<Float>, _ body: (Int, Float) -> Void) {
            forEachNeighbor(of: p, radiusCells: 1, body)
        }

        /// Same, over the (2r+1)³ block — the adaptive path widens the search
        /// where the base support found no points.
        func forEachNeighbor(of p: SIMD3<Float>, radiusCells: Int32,
                             _ body: (Int, Float) -> Void) {
            let base = key(p)
            for dz in -radiusCells...radiusCells {
                for dy in -radiusCells...radiusCells {
                    for dx in -radiusCells...radiusCells {
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
