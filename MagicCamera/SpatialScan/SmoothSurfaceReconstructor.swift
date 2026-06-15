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
//  Bounded *and* offloaded so it stays detailed without taking forever: the
//  lattice resolution is capped to the cloud's extent, the working point set is
//  budgeted, spatial-hash keys are packed into a single Int64, and the per-corner
//  field — the dominant cost — is evaluated in one batch on the GPU
//  (`GPUSurfaceField`) with a multicore CPU fallback. A deadline plus a
//  cancellation check guarantee it can never spin past the OS CPU budget.
//

import Foundation
import simd

enum SmoothSurfaceReconstructor {

    /// Largest lattice count along the longest axis. Small subjects (short
    /// extent) resolve fine detail here; room-scale clouds are reined in by the
    /// working-point budget below, which coarsens the cell size so the band
    /// never explodes. The field offload (GPU / multicore CPU) is what makes
    /// this resolution affordable.
    private static let maxLatticeResolution = 256
    /// Working-set budget after decimation. Surface points scale with 1/cell²,
    /// so a room-scale cloud is coarsened until it fits — keeping the field band
    /// (≈ working points × ~8) comfortably under `maxBandCells`.
    private static let workingPointBudget = 160_000
    /// Hard ceiling on band cells. A safety net only.
    private static let maxBandCells = 1_600_000
    /// Wall-clock safety net for the polygonise pass.
    private static let evaluationDeadline: TimeInterval = 25

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

        let effectiveResolution = min(max(resolution, 16), maxLatticeResolution)
        var cellSize = max(maxExtent / Float(effectiveResolution), 0.002)

        // Decimate to the field's working resolution, carrying supplied normals
        // through the same subsample so Fusion's measured rays stay aligned.
        let suppliedNormals: [SIMD3<Float>]? = (normals?.count == cloud.count) ? normals : nil

        func decimate(_ cell: Float) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
            let dedup = max(cell * 0.5, 1e-4)
            var seen = Set<Int64>()
            seen.reserveCapacity(min(cloud.count, 600_000))
            var positions: [SIMD3<Float>] = []
            positions.reserveCapacity(min(cloud.count, 600_000))
            var pointNormals: [SIMD3<Float>] = []
            if suppliedNormals != nil { pointNormals.reserveCapacity(min(cloud.count, 600_000)) }
            for i in 0..<cloud.count {
                let p = cloud.positions[i]
                let s = p / dedup
                let key = Self.packCell(Int32(s.x.rounded(.down)),
                                        Int32(s.y.rounded(.down)),
                                        Int32(s.z.rounded(.down)))
                guard seen.insert(key).inserted else { continue }
                positions.append(p)
                if let suppliedNormals { pointNormals.append(suppliedNormals[i]) }
            }
            return (positions, pointNormals)
        }

        var (positions, pointNormals) = decimate(cellSize)
        if positions.count > workingPointBudget {
            let factor = (Double(positions.count) / Double(workingPointBudget)).squareRoot()
            cellSize *= Float(min(max(factor, 1), 6))
            (positions, pointNormals) = decimate(cellSize)
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

        // Pad so the surface band never touches the lattice boundary.
        let origin = box.min - SIMD3<Float>(repeating: cellSize * 2)
        let support = cellSize * 2.2

        // Narrow band: every lattice cell within 1 cell of any point. Packed
        // keys for cheap dedup; unpacked back to lattice coords when emitting.
        var band = Set<Int64>()
        band.reserveCapacity(positions.count * 4)
        for p in positions {
            let s = (p - origin) / cellSize
            let bx = Int32(s.x.rounded(.down))
            let by = Int32(s.y.rounded(.down))
            let bz = Int32(s.z.rounded(.down))
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        band.insert(Self.packCell(bx &+ dx, by &+ dy, bz &+ dz))
                    }
                }
            }
        }
        guard !band.isEmpty, band.count < maxBandCells else { return nil }
        if Task.isCancelled { return nil }

        // Unique lattice corners needed by the band cells (8 per cell). The
        // world position of each is the field query point; the index map lets
        // the cell-build pass read each corner's field value back.
        var cornerIndex: [Int64: Int32] = [:]
        cornerIndex.reserveCapacity(band.count * 2)
        var queries: [SIMD3<Float>] = []
        queries.reserveCapacity(band.count * 2)
        for packed in band {
            let base = Self.unpackCell(packed)
            for offset in MarchingCubes.cornerOffsets {
                let c = base &+ offset
                let key = Self.packCell(c.x, c.y, c.z)
                if cornerIndex[key] == nil {
                    cornerIndex[key] = Int32(queries.count)
                    queries.append(origin + SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)) * cellSize)
                }
            }
        }
        if Task.isCancelled { return nil }

        // The heavy step, offloaded: GPU first, multicore CPU fallback. `.infinity`
        // marks a corner with no points in range (outside the narrow band).
        let field = evaluateField(queries: queries, positions: positions,
                                  normals: pointNormals, support: support)
        if Task.isCancelled { return nil }

        // Emit complete cells for marching cubes.
        let deadline = Date().addingTimeInterval(evaluationDeadline)
        var cells: [MarchingCubes.Cell] = []
        cells.reserveCapacity(band.count / 2)
        var processed = 0
        for packed in band {
            if processed & 0x3FFF == 0 {
                if Task.isCancelled { return nil }
                if Date() > deadline { break }
            }
            processed += 1
            let base = Self.unpackCell(packed)
            var values = [Float](repeating: 0, count: 8)
            var complete = true
            for (i, offset) in MarchingCubes.cornerOffsets.enumerated() {
                let c = base &+ offset
                let idx = Int(cornerIndex[Self.packCell(c.x, c.y, c.z)] ?? -1)
                let v = idx >= 0 ? field[idx] : Float.infinity
                guard v.isFinite else { complete = false; break }
                values[i] = v
            }
            guard complete else { continue }
            cells.append(MarchingCubes.Cell(
                base: base,
                values: (values[0], values[1], values[2], values[3],
                         values[4], values[5], values[6], values[7])))
        }
        guard !cells.isEmpty else { return nil }

        return MarchingCubes.mesh(cells: cells, origin: origin, cellSize: cellSize)
    }

    // MARK: - Field evaluation (GPU offload + multicore CPU fallback)

    /// Field value at every query corner. Tries the GPU compute kernel first;
    /// falls back to the parallel CPU path when Metal is unavailable or fails.
    private static func evaluateField(queries: [SIMD3<Float>],
                                      positions: [SIMD3<Float>],
                                      normals: [SIMD3<Float>],
                                      support: Float) -> [Float] {
        if let gpu = GPUSurfaceField.evaluate(queries: queries, positions: positions,
                                              normals: normals, support: support) {
            Diagnostics.shared.gpu("surface-field", used: true, "\(queries.count) corners")
            return gpu
        }
        Diagnostics.shared.gpu("surface-field", used: false, "\(queries.count) corners")
        return cpuField(queries: queries, positions: positions, normals: normals, support: support)
    }

    /// Multicore CPU field evaluation — one parallel task per corner over a
    /// shared read-only spatial hash (each writes a distinct output slot).
    private static func cpuField(queries: [SIMD3<Float>],
                                 positions: [SIMD3<Float>],
                                 normals: [SIMD3<Float>],
                                 support: Float) -> [Float] {
        let grid = SupportGrid(points: positions, cell: support)
        let inv2s2 = 1 / (2 * support * support)
        let supportSq = support * support
        var out = [Float](repeating: .infinity, count: queries.count)
        out.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: queries.count) { i in
                let x = queries[i]
                var weightSum: Float = 0
                var valueSum: Float = 0
                grid.forEachNeighbor(of: x) { index, d2 in
                    guard d2 < supportSq else { return }
                    let w = expf(-d2 * inv2s2)
                    weightSum += w
                    valueSum += w * simd_dot(x - positions[index], normals[index])
                }
                base[i] = weightSum > 1e-6 ? valueSum / weightSum : .infinity
            }
        }
        return out
    }

    // MARK: - Packed lattice keys

    /// Packs a lattice cell into a single Int64 (21 bits/axis, biased so
    /// negatives pack too). Matches `packedCellKey` in ScanCompute.metal /
    /// `GPUPointProcessor.cellKey`. Bounded resolution keeps coordinates inside
    /// ±2²⁰.
    @inline(__always)
    private static func packCell(_ x: Int32, _ y: Int32, _ z: Int32) -> Int64 {
        let bias: Int64 = 0x100000   // 2²⁰
        let px = (Int64(x) &+ bias) & 0x1FFFFF
        let py = (Int64(y) &+ bias) & 0x1FFFFF
        let pz = (Int64(z) &+ bias) & 0x1FFFFF
        return (px << 42) | (py << 21) | pz
    }

    @inline(__always)
    private static func unpackCell(_ key: Int64) -> SIMD3<Int32> {
        let bias: Int64 = 0x100000
        let mask: Int64 = 0x1FFFFF
        let x = Int32(((key >> 42) & mask) &- bias)
        let y = Int32(((key >> 21) & mask) &- bias)
        let z = Int32((key & mask) &- bias)
        return SIMD3<Int32>(x, y, z)
    }

    /// Uniform spatial hash that streams neighbours in the 3×3×3 block around a
    /// query point (cell size = field support radius). Packed Int64 buckets.
    /// Read-only after `init`, so it is safe to share across the parallel field
    /// evaluation.
    private struct SupportGrid {
        let cell: Float
        private let points: [SIMD3<Float>]
        private var buckets: [Int64: [Int]] = [:]

        init(points: [SIMD3<Float>], cell: Float) {
            self.cell = max(cell, 1e-4)
            self.points = points
            buckets.reserveCapacity(points.count)
            for (i, p) in points.enumerated() { buckets[key(p), default: []].append(i) }
        }

        private func key(_ p: SIMD3<Float>) -> Int64 {
            let s = p / cell
            return SmoothSurfaceReconstructor.packCell(Int32((s.x).rounded(.down)),
                                                       Int32((s.y).rounded(.down)),
                                                       Int32((s.z).rounded(.down)))
        }

        /// Calls `body(index, squaredDistance)` for every point in the 3×3×3
        /// block of cells around `p`.
        func forEachNeighbor(of p: SIMD3<Float>, _ body: (Int, Float) -> Void) {
            let s = p / cell
            let bx = Int32(s.x.rounded(.down))
            let by = Int32(s.y.rounded(.down))
            let bz = Int32(s.z.rounded(.down))
            for dz in Int32(-1)...1 {
                for dy in Int32(-1)...1 {
                    for dx in Int32(-1)...1 {
                        let k = SmoothSurfaceReconstructor.packCell(bx &+ dx, by &+ dy, bz &+ dz)
                        guard let bucket = buckets[k] else { continue }
                        for index in bucket {
                            body(index, simd_distance_squared(points[index], p))
                        }
                    }
                }
            }
        }
    }
}
