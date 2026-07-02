//
//  AdaptiveMesher.swift
//  Magic Camera
//
//  Turns an AdaptiveOctree partition into a triangle mesh at variable resolution —
//  the second piece of variable-resolution reconstruction (after the octree, before
//  the area-proportional atlas). Each leaf carries the cell size its geometry needs;
//  this marching-cubes each resolution level separately (so the shared-edge vertex
//  dedup keeps every level internally crack-free) and welds the levels together.
//
//  The signed field is supplied as a closure so the mesher is independent of its
//  source — an analytic field in tests, a point-derived field (nearest-point normal,
//  or the GPU TSDF the uniform reconstructor already uses) in production.
//
//  Known v1 limitation: a coarse leaf's face meets several finer leaves' faces at a
//  T-junction, so a hairline crack can remain along a coarse↔fine boundary. Welding
//  joins the shared corners; the remaining seams are left for a follow-up (a
//  restricted 2:1 octree with transition cells, or a hole-fill pass). Not yet wired
//  into the live pipeline.
//
//  Pure value math, off-main, unit-testable.
//

import simd

enum AdaptiveMesher {
    /// Meshes `octree` by evaluating `sdf` (iso-level 0, negative = inside) at the
    /// leaves' corners. Returns nil when nothing crosses the surface.
    static func mesh(_ octree: AdaptiveOctree.Result,
                     sdf: (SIMD3<Float>) -> Float?) -> MeshData? {
        let leaves = octree.leaves
        guard !leaves.isEmpty else { return nil }
        let origin = octree.rootMin

        // Corner value cache: a corner shared by neighbouring leaves (within or
        // across levels, where the lattices align) is evaluated once and reused, so
        // coincident corners always agree. Keyed by a fine quantisation of the
        // corner's world position. `.infinity` marks a corner the field left
        // undefined (no nearby points), so it isn't re-evaluated and the cell is
        // skipped rather than marched with a made-up value.
        let quantum = max(octree.minLeafSize * 0.05, 1e-4)
        var cache: [SIMD3<Int32>: Float] = [:]
        cache.reserveCapacity(leaves.count * 4)
        func value(_ p: SIMD3<Float>) -> Float? {
            let key = SIMD3<Int32>((p / quantum).rounded(.toNearestOrAwayFromZero))
            if let v = cache[key] { return v.isFinite ? v : nil }
            let v = sdf(p) ?? .infinity
            cache[key] = v
            return v.isFinite ? v : nil
        }

        // Group leaves by exact size (powers-of-two of the root, so bit-identical
        // within a level) and marching-cubes each level on its own lattice.
        var byLevel: [Float: [AdaptiveOctree.Leaf]] = [:]
        for leaf in leaves { byLevel[leaf.size, default: []].append(leaf) }

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for (size, levelLeaves) in byLevel {
            guard size > 0 else { continue }
            var cells: [MarchingCubes.Cell] = []
            cells.reserveCapacity(levelLeaves.count)
            for leaf in levelLeaves {
                let base = SIMD3<Int32>(((leaf.min - origin) / size).rounded(.toNearestOrAwayFromZero))
                // Skip a cell any of whose corners the field left undefined — that's a
                // genuine gap in the data, so leave a hole there rather than marching
                // an incomplete cell into a spurious fragment (the old shatter).
                var corners = [Float](repeating: 0, count: 8)
                var complete = true
                for c in 0..<8 {
                    let o = MarchingCubes.cornerOffsets[c]
                    let world = leaf.min + SIMD3<Float>(Float(o.x), Float(o.y), Float(o.z)) * size
                    guard let s = value(world) else { complete = false; break }
                    corners[c] = s
                }
                guard complete else { continue }
                cells.append(MarchingCubes.Cell(
                    base: base,
                    values: (corners[0], corners[1], corners[2], corners[3],
                             corners[4], corners[5], corners[6], corners[7])))
            }
            guard let levelMesh = MarchingCubes.mesh(cells: cells, origin: origin, cellSize: size)
            else { continue }
            let offset = UInt32(vertices.count)
            vertices.append(contentsOf: levelMesh.vertices)
            normals.append(contentsOf: levelMesh.normals)
            indices.append(contentsOf: levelMesh.indices.map { $0 + offset })
        }

        guard vertices.count >= 3, indices.count >= 3 else { return nil }
        // Weld coincident vertices to join the levels where their corners align,
        // then stitch the coarse↔fine T-junctions the weld leaves behind.
        let welded = MeshData(vertices: vertices, normals: normals, indices: indices)
            .weldingDuplicateVertices()
        return stitchTJunctions(welded, quantum: octree.minLeafSize)
    }

    // MARK: - T-junction stitching

    /// Closes the hairline cracks a level boundary leaves. Where a coarse leaf's face
    /// edge is bisected by a finer leaf's vertex, the coarse triangle spans the whole
    /// edge while the fine triangles stop at the midpoint — a T-junction, and the two
    /// sides can part into a visible slit. Because the level lattices are aligned, the
    /// finer vertex lies *exactly* on the coarse edge, so we find it and split the
    /// coarse triangle through it, welding the crack shut. A real open-surface
    /// boundary has no vertex on its interior and is left untouched. Positions never
    /// move (only re-triangulation), so the welded normals stay valid. Bounded, so a
    /// pathological mesh can't run the review-time job away.
    static func stitchTJunctions(_ mesh: MeshData, quantum: Float) -> MeshData {
        var tris = mesh.indices
        let verts = mesh.vertices
        let triCount = tris.count / 3
        guard verts.count >= 3, triCount >= 2, triCount <= 400_000 else { return mesh }
        let cell = max(quantum, 1e-4)

        func gkey(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            let s = p / cell
            return SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
        }
        // Vertices don't move, so the spatial hash is built once and reused.
        var grid: [SIMD3<Int32>: [UInt32]] = [:]
        grid.reserveCapacity(verts.count)
        for i in 0..<verts.count { grid[gkey(verts[i]), default: []].append(UInt32(i)) }

        func ekey(_ a: UInt32, _ b: UInt32) -> UInt64 {
            (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
        }
        // The vertex sitting on the open segment (p,q), closest to p, or nil.
        func tVertex(_ p: UInt32, _ q: UInt32, _ r: UInt32) -> UInt32? {
            let origin = verts[Int(p)], target = verts[Int(q)]
            let seg = target - origin
            let len2 = simd_length_squared(seg)
            guard len2 > 1e-10 else { return nil }
            let tol = cell * 0.25
            let steps = max(Int((len2.squareRoot() / cell).rounded(.up)), 1)
            var best: UInt32?
            var bestS: Float = 2
            for k in 0...steps {
                let base = gkey(origin + seg * (Float(k) / Float(steps)))
                for dz in Int32(-1)...1 { for dy in Int32(-1)...1 { for dx in Int32(-1)...1 {
                    guard let bucket = grid[base &+ SIMD3<Int32>(dx, dy, dz)] else { continue }
                    for vi in bucket where vi != p && vi != q && vi != r {
                        let s = simd_dot(verts[Int(vi)] - origin, seg) / len2
                        guard s > 0.02, s < 0.98, s < bestS else { continue }
                        if simd_distance(verts[Int(vi)], origin + seg * s) <= tol {
                            bestS = s; best = vi
                        }
                    }
                } } }
            }
            return best
        }

        // A T-vertex can bisect an edge repeatedly (a 4:1 ratio leaves several), so
        // iterate: each pass splits one per triangle and re-examines the pieces.
        for _ in 0..<4 {
            var edgeCount: [UInt64: Int] = [:]
            edgeCount.reserveCapacity(tris.count)
            var t = 0
            while t < tris.count {
                let a = tris[t], b = tris[t + 1], c = tris[t + 2]
                edgeCount[ekey(a, b), default: 0] += 1
                edgeCount[ekey(b, c), default: 0] += 1
                edgeCount[ekey(c, a), default: 0] += 1
                t += 3
            }
            var out: [UInt32] = []
            out.reserveCapacity(tris.count)
            var didSplit = false
            t = 0
            while t < tris.count {
                let a = tris[t], b = tris[t + 1], c = tris[t + 2]
                var handled = false
                // Only boundary edges (used once) can host a crack; a shared interior
                // edge already agrees on both sides.
                for (p, q, r) in [(a, b, c), (b, c, a), (c, a, b)] where edgeCount[ekey(p, q)] == 1 {
                    if let v = tVertex(p, q, r) {
                        out.append(contentsOf: [p, v, r, v, q, r])   // preserves winding
                        didSplit = true; handled = true
                        break
                    }
                }
                if !handled { out.append(contentsOf: [a, b, c]) }
                t += 3
            }
            tris = out
            if !didSplit { break }
        }
        return MeshData(vertices: verts, normals: mesh.normals, indices: tris,
                        classifications: mesh.classifications)
    }

    // MARK: - Point-derived signed field

    /// Smooth signed field for the adaptive path: a Gaussian-weighted signed distance
    /// (Hoppe-style — the weighted average of `dot(x − pᵢ, nᵢ)` over nearby points)
    /// with a *density-adaptive* bandwidth. Two properties the old nearest-point field
    /// lacked, and which made it shatter on real LiDAR:
    ///
    ///   • Smoothness — averaging over neighbours (not a single nearest point) gives a
    ///     continuous field, so marching cubes traces a clean surface instead of a
    ///     jagged one.
    ///   • Density adaptivity — the search expands until it finds `k` points and the
    ///     bandwidth is the distance to the k-th of them, so a fine query in a *sparse*
    ///     region (a far, thinly-scanned wall) still resolves a solid surface, while a
    ///     dense region stays sharp. `nil` (not a positive sentinel) is returned only
    ///     where there are genuinely too few points, so the mesher leaves a real hole
    ///     there instead of a spurious fragment.
    ///
    /// Position-only, so a corner shared across octree levels evaluates identically —
    /// the mesher's cache and the level weld both rely on that.
    struct SmoothField {
        private let positions: [SIMD3<Float>]
        private let normals: [SIMD3<Float>]
        private let cell: Float
        private let maxRadius: Int
        private let k: Int
        private var grid: [SIMD3<Int32>: [Int32]] = [:]

        /// - cell: hash cell ≈ the fine point spacing (minCell). Dense queries resolve
        ///   in the first 3×3×3; sparse ones expand out to `maxSupport`.
        /// - maxSupport: the coarsest search reach (≈ maxCell) before a query is nil.
        init(positions: [SIMD3<Float>], normals: [SIMD3<Float>],
             cell: Float, maxSupport: Float, k: Int = 6) {
            self.positions = positions
            self.normals = normals
            self.cell = max(cell, 1e-4)
            self.maxRadius = max(1, Int((maxSupport / max(cell, 1e-4)).rounded(.up)))
            self.k = k
            grid.reserveCapacity(positions.count)
            for i in 0..<positions.count { grid[key(positions[i]), default: []].append(Int32(i)) }
        }

        private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            let s = p / cell
            return SIMD3<Int32>(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
        }

        func value(at x: SIMD3<Float>) -> Float? {
            let base = key(x)
            var neigh: [(d2: Float, idx: Int)] = []
            var r = 1
            while r <= maxRadius {
                neigh.removeAll(keepingCapacity: true)
                for dz in -r...r { for dy in -r...r { for dx in -r...r {
                    guard let bucket = grid[base &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))]
                    else { continue }
                    for j in bucket { neigh.append((simd_distance_squared(x, positions[Int(j)]), Int(j))) }
                } } }
                if neigh.count >= k { break }
                r = r < 2 ? 2 : r * 2
            }
            guard neigh.count >= k else { return nil }
            neigh.sort { $0.d2 < $1.d2 }
            let h = max(neigh[k - 1].d2.squareRoot(), cell * 0.5)
            let inv2h2 = 1 / (2 * h * h)
            var weightSum: Float = 0, valueSum: Float = 0
            for (d2, j) in neigh {
                let w = expf(-d2 * inv2h2)
                weightSum += w
                valueSum += w * simd_dot(x - positions[j], normals[j])
            }
            return weightSum > 1e-6 ? valueSum / weightSum : nil
        }
    }
}
