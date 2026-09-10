//
//  MeshDecimator.swift
//  Magic Camera
//
//  Reduces triangle count by vertex clustering: vertices falling in the same grid
//  cell collapse to one representative, triangles are remapped, and degenerate
//  ones are dropped. The representative is placed at the point that minimises the
//  quadric error of the cell's incident triangle planes (Lindstrom-style), so
//  sharp features — corners, edges — survive instead of being rounded off by a
//  plain average. Falls back to the cell centroid on flat (rank-deficient) cells.
//
//  Robust on "soup" meshes (no shared connectivity needed, no edge-collapse) and
//  pure value math — runs off the main thread and is unit-testable. Preserves
//  per-vertex classification (majority per cell).
//

import simd

enum MeshDecimator {
    /// Clusters vertices onto a grid of roughly `gridResolution` cells along the
    /// longest axis. Lower resolution = fewer triangles.
    /// `isCancelled` is polled between the three passes; a cancelled decimate
    /// returns the input unchanged rather than a partly-clustered mesh.
    static func decimate(_ mesh: MeshData, gridResolution: Int = 96,
                         isCancelled: () -> Bool = { false }) -> MeshData {
        guard mesh.count >= 4, mesh.indices.count >= 3, let box = mesh.boundingBox() else { return mesh }
        let extent = box.max - box.min
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        guard maxExtent > 0 else { return mesh }
        let cell = max(maxExtent / Float(max(gridResolution, 4)), 0.002)
        let origin = box.min
        let hasClass = mesh.hasClassification

        // Pass 1 — cluster vertices by cell; keep the centroid (fallback target),
        // the cell key (for bounds clamping) and the classification vote.
        var cluster = [SIMD3<Int32>: UInt32](minimumCapacity: mesh.count / 2)
        var keys: [SIMD3<Int32>] = []
        var sums: [SIMD3<Float>] = []
        var counts: [Float] = []
        var classVotes: [[UInt8: Int]] = []
        var remap = [UInt32](repeating: 0, count: mesh.count)

        for i in 0..<mesh.count {
            let key = cellKey(mesh.vertices[i], origin: origin, cell: cell)
            if let idx = cluster[key] {
                sums[Int(idx)] += mesh.vertices[i]
                counts[Int(idx)] += 1
                if hasClass { classVotes[Int(idx)][mesh.classifications[i], default: 0] += 1 }
                remap[i] = idx
            } else {
                let idx = UInt32(sums.count)
                cluster[key] = idx
                keys.append(key)
                sums.append(mesh.vertices[i])
                counts.append(1)
                classVotes.append(hasClass ? [mesh.classifications[i]: 1] : [:])
                remap[i] = idx
            }
        }

        if isCancelled() { return mesh }
        // Pass 2 — accumulate each triangle's (area-weighted) plane quadric into
        // the quadric of all three of its vertices' clusters.
        var quadrics = [Quadric](repeating: Quadric(), count: sums.count)
        var t = 0
        while t + 2 < mesh.indices.count {
            let ia = Int(mesh.indices[t]), ib = Int(mesh.indices[t + 1]), ic = Int(mesh.indices[t + 2])
            let v0 = mesh.vertices[ia], v1 = mesh.vertices[ib], v2 = mesh.vertices[ic]
            let cross = simd_cross(v1 - v0, v2 - v0)
            let len = simd_length(cross)
            if len > 1e-12 {
                let n = cross / len
                let area = Double(0.5 * len)
                let d = Double(-simd_dot(n, v0))
                let na = Double(n.x), nb = Double(n.y), nc = Double(n.z)
                quadrics[Int(remap[ia])].addPlane(na, nb, nc, d, weight: area)
                quadrics[Int(remap[ib])].addPlane(na, nb, nc, d, weight: area)
                quadrics[Int(remap[ic])].addPlane(na, nb, nc, d, weight: area)
            }
            t += 3
        }

        // Pass 3 — representative per cluster: the quadric-optimal point when it
        // is well-conditioned and lands near the cell, else the centroid.
        let newVertices: [SIMD3<Float>] = (0..<sums.count).map { i in
            let centroid = sums[i] / counts[i]
            guard let optimal = quadrics[i].optimalPoint() else { return centroid }
            // Reject a solve that flings the vertex far outside its own cell.
            let cellMin = origin + SIMD3<Float>(Float(keys[i].x), Float(keys[i].y), Float(keys[i].z)) * cell
            let lo = cellMin - SIMD3<Float>(repeating: cell)
            let hi = cellMin + SIMD3<Float>(repeating: cell * 2)
            guard all(optimal .>= lo) && all(optimal .<= hi) else { return centroid }
            return optimal
        }

        if isCancelled() { return mesh }
        // Pass 4 — remap triangles, dropping ones that collapsed to a line/point.
        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(mesh.indices.count)
        t = 0
        while t + 2 < mesh.indices.count {
            let a = remap[Int(mesh.indices[t])]
            let b = remap[Int(mesh.indices[t + 1])]
            let c = remap[Int(mesh.indices[t + 2])]
            if a != b, b != c, a != c {
                newIndices.append(a); newIndices.append(b); newIndices.append(c)
            }
            t += 3
        }
        guard !newIndices.isEmpty else { return mesh }

        let classifications: [UInt8] = hasClass
            ? classVotes.map { votes in votes.max(by: { $0.value < $1.value })?.key ?? 0 }
            : []
        let normals = computeNormals(vertices: newVertices, indices: newIndices)
        return MeshData(vertices: newVertices, normals: normals,
                        indices: newIndices, classifications: classifications)
    }

    /// Progressive (adaptive-resolution) decimation: flat regions collapse onto a
    /// coarse grid — a wall becomes a handful of big triangles — while curved
    /// detail keeps the fine grid, so triangle size follows the geometry instead of
    /// being uniform everywhere. The cell size per vertex steps with its local
    /// flatness (`|mean incident face normal|`: 1 = flat, →0 = a crease), nested in
    /// powers of two so the grids align and the result stays a valid triangulation
    /// (vertex clustering inserts no edge splits, so no T-junctions / cracks).
    /// `baseResolution` sets the *finest* grid (detail); flat regions go 2–4× coarser.
    static func adaptiveDecimate(_ mesh: MeshData, baseResolution: Int = 160) -> MeshData {
        let welded = mesh.weldingDuplicateVertices()
        guard welded.count >= 8, welded.indices.count >= 6, let box = welded.boundingBox() else { return mesh }
        let extent = box.max - box.min
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        guard maxExtent > 0 else { return mesh }
        let baseCell = max(maxExtent / Float(max(baseResolution, 8)), 0.003)
        let origin = box.min
        let hasClass = welded.hasClassification
        let flatness = vertexFlatness(welded)

        // Level → cell multiplier (power of two so the grids nest cleanly).
        func level(_ f: Float) -> Int32 {
            if f > 0.985 { return 2 }   // wall/floor flat → 4× cell, big triangles
            if f > 0.94 { return 1 }    // gently curved → 2× cell
            return 0                    // crease / detail → finest grid, preserved
        }

        // Pass 1 — cluster by (cell, level); a vertex only merges with same-level
        // neighbours in the same cell, so a flat patch coarsens without dragging in
        // the detail beside it.
        var cluster = [SIMD4<Int32>: UInt32](minimumCapacity: welded.count / 2)
        var sums: [SIMD3<Float>] = []
        var counts: [Float] = []
        var cellSizes: [Float] = []
        var centroidsMinCorner: [SIMD3<Float>] = []
        var classVotes: [[UInt8: Int]] = []
        var remap = [UInt32](repeating: 0, count: welded.count)
        for i in 0..<welded.count {
            let lvl = level(flatness[i])
            let cell = baseCell * Float(1 << Int(lvl))
            let s = (welded.vertices[i] - origin) / cell
            let qx = Int32(s.x.rounded(.down)), qy = Int32(s.y.rounded(.down)), qz = Int32(s.z.rounded(.down))
            let key = SIMD4<Int32>(qx, qy, qz, lvl)
            if let idx = cluster[key] {
                sums[Int(idx)] += welded.vertices[i]; counts[Int(idx)] += 1
                if hasClass { classVotes[Int(idx)][welded.classifications[i], default: 0] += 1 }
                remap[i] = idx
            } else {
                let idx = UInt32(sums.count)
                cluster[key] = idx
                sums.append(welded.vertices[i]); counts.append(1)
                cellSizes.append(cell)
                centroidsMinCorner.append(origin + SIMD3<Float>(Float(qx), Float(qy), Float(qz)) * cell)
                classVotes.append(hasClass ? [welded.classifications[i]: 1] : [:])
                remap[i] = idx
            }
        }

        // Pass 2 — area-weighted plane quadric per cluster (sharp-feature preserving).
        var quadrics = [Quadric](repeating: Quadric(), count: sums.count)
        var t = 0
        while t + 2 < welded.indices.count {
            let ia = Int(welded.indices[t]), ib = Int(welded.indices[t + 1]), ic = Int(welded.indices[t + 2])
            let v0 = welded.vertices[ia], v1 = welded.vertices[ib], v2 = welded.vertices[ic]
            let cross = simd_cross(v1 - v0, v2 - v0)
            let len = simd_length(cross)
            if len > 1e-12 {
                let nrm = cross / len
                let area = Double(0.5 * len), dd = Double(-simd_dot(nrm, v0))
                quadrics[Int(remap[ia])].addPlane(Double(nrm.x), Double(nrm.y), Double(nrm.z), dd, weight: area)
                quadrics[Int(remap[ib])].addPlane(Double(nrm.x), Double(nrm.y), Double(nrm.z), dd, weight: area)
                quadrics[Int(remap[ic])].addPlane(Double(nrm.x), Double(nrm.y), Double(nrm.z), dd, weight: area)
            }
            t += 3
        }

        // Pass 3 — quadric-optimal representative, rejected back to the centroid
        // when it lands more than a cell away (keeps a bad solve from spiking out).
        let newVertices: [SIMD3<Float>] = (0..<sums.count).map { i in
            let centroid = sums[i] / counts[i]
            guard let optimal = quadrics[i].optimalPoint() else { return centroid }
            let lo = centroidsMinCorner[i] - SIMD3<Float>(repeating: cellSizes[i])
            let hi = centroidsMinCorner[i] + SIMD3<Float>(repeating: cellSizes[i] * 2)
            guard all(optimal .>= lo) && all(optimal .<= hi) else { return centroid }
            return optimal
        }

        // Pass 4 — remap triangles, dropping ones that collapsed to a line/point.
        var newIndices: [UInt32] = []
        newIndices.reserveCapacity(welded.indices.count)
        t = 0
        while t + 2 < welded.indices.count {
            let a = remap[Int(welded.indices[t])], b = remap[Int(welded.indices[t + 1])], c = remap[Int(welded.indices[t + 2])]
            if a != b, b != c, a != c { newIndices.append(a); newIndices.append(b); newIndices.append(c) }
            t += 3
        }
        guard !newIndices.isEmpty else { return mesh }

        let classifications: [UInt8] = hasClass
            ? classVotes.map { $0.max(by: { $0.value < $1.value })?.key ?? 0 } : []
        let normals = computeNormals(vertices: newVertices, indices: newIndices)
        return MeshData(vertices: newVertices, normals: normals,
                        indices: newIndices, classifications: classifications)
    }

    /// Per-vertex flatness in [0, 1]: the length of the mean of its incident unit
    /// face normals. 1 where every incident face agrees (a flat patch), falling
    /// toward 0 at a crease or corner where the normals fan out.
    private static func vertexFlatness(_ mesh: MeshData) -> [Float] {
        var sum = [SIMD3<Float>](repeating: .zero, count: mesh.count)
        var count = [Float](repeating: 0, count: mesh.count)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
            let cross = simd_cross(mesh.vertices[b] - mesh.vertices[a], mesh.vertices[c] - mesh.vertices[a])
            let len = simd_length(cross)
            if len > 1e-12 {
                let n = cross / len
                sum[a] += n; sum[b] += n; sum[c] += n
                count[a] += 1; count[b] += 1; count[c] += 1
            }
            i += 3
        }
        return (0..<mesh.count).map { count[$0] > 0 ? simd_length(sum[$0]) / count[$0] : 1 }
    }

    /// Accumulated quadric (sum of area-weighted plane outer products K = w·p·pᵀ,
    /// p = (a, b, c, d)). Symmetric 4×4 kept as its 10 unique entries in double
    /// precision — quadrics sum large values, where Float would lose the corner.
    private struct Quadric {
        var c00 = 0.0, c01 = 0.0, c02 = 0.0, c03 = 0.0
        var c11 = 0.0, c12 = 0.0, c13 = 0.0
        var c22 = 0.0, c23 = 0.0
        var c33 = 0.0

        mutating func addPlane(_ a: Double, _ b: Double, _ c: Double, _ d: Double, weight w: Double) {
            c00 += w * a * a; c01 += w * a * b; c02 += w * a * c; c03 += w * a * d
            c11 += w * b * b; c12 += w * b * c; c13 += w * b * d
            c22 += w * c * c; c23 += w * c * d
            c33 += w * d * d
        }

        /// Point minimising xᵀKx: solve A·x = −(c03, c13, c23) with A the
        /// top-left 3×3. Nil when A is (near-)singular — a flat or under-
        /// constrained cell, where the centroid is the right fallback.
        func optimalPoint() -> SIMD3<Float>? {
            let A = simd_double3x3(SIMD3(c00, c01, c02),
                                   SIMD3(c01, c11, c12),
                                   SIMD3(c02, c12, c22))
            let det = simd_determinant(A)
            guard abs(det) > 1e-10 else { return nil }
            let x = A.inverse * SIMD3<Double>(-c03, -c13, -c23)
            guard x.x.isFinite, x.y.isFinite, x.z.isFinite else { return nil }
            return SIMD3<Float>(Float(x.x), Float(x.y), Float(x.z))
        }
    }

    private static func cellKey(_ p: SIMD3<Float>, origin: SIMD3<Float>, cell: Float) -> SIMD3<Int32> {
        let s = (p - origin) / cell
        return SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
    }

    private static func computeNormals(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let faceNormal = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            normals[a] += faceNormal; normals[b] += faceNormal; normals[c] += faceNormal
            i += 3
        }
        for v in 0..<normals.count {
            let length = simd_length(normals[v])
            normals[v] = length > 1e-6 ? normals[v] / length : SIMD3<Float>(0, 1, 0)
        }
        return normals
    }
}
