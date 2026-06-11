//
//  BallPivotingMesher.swift
//  Magic Camera
//
//  Ball-Pivoting surface reconstruction (Bernardini et al. 1999): a ball of
//  radius ρ pivots around mesh-front edges; every point triple the ball can
//  rest on without containing another point becomes a triangle. Interpolating
//  (uses the scan points as the mesh vertices, unlike voxel/marching-cubes
//  reconstruction), so fine detail survives. Runs multiple passes with growing
//  radii so sparser regions get bridged after dense ones are meshed.
//
//  Pure value math — ARKit-free, off-main-thread friendly, unit-testable.
//

import simd

enum BallPivotingMesher {
    /// Reconstructs a triangle mesh, or nil when the cloud is too sparse.
    /// Clouds larger than `maxPoints` are strided down first (BPA cost grows
    /// steeply with point count). `radiusMultipliers` scale the estimated mean
    /// point spacing into the pivot-ball radii for the successive passes.
    static func reconstruct(_ cloud: PointCloud,
                            normals suppliedNormals: [SIMD3<Float>]? = nil,
                            maxPoints: Int = 90_000,
                            radiusMultipliers: [Float] = [1.6, 2.4, 3.5]) -> MeshData? {
        guard cloud.count >= 50 else { return nil }
        // Poisson-disk keeps blue-noise spacing (stride sampling thins detail
        // unevenly, which starves the pivot ball in exactly the worst places).
        let working = cloud.count > maxPoints
            ? PointCloudSampler.poissonDisk(cloud, targetCount: maxPoints)
            : cloud
        let points = working.positions
        let n = points.count
        guard n >= 50 else { return nil }

        // Normals: reuse only when they are still index-aligned (no downsampling).
        let normals: [SIMD3<Float>]
        if let suppliedNormals, suppliedNormals.count == n {
            normals = suppliedNormals
        } else {
            normals = PointCloudNormals.estimate(working)
        }

        guard let spacing = meanSpacing(points) else { return nil }
        let radii = radiusMultipliers.map { max($0 * spacing, 1e-4) }
        guard let maxRadius = radii.max() else { return nil }

        // Cell = 2·ρmax so a 3×3×3 block reaches every candidate within 2ρ.
        let grid = Grid(points: points, cell: maxRadius * 2)
        var builder = FrontBuilder(points: points, normals: normals, grid: grid)

        for radius in radii {
            builder.reactivateBoundary()
            var madeProgress = true
            while madeProgress {
                builder.expandFront(radius: radius)
                madeProgress = builder.seedTriangle(radius: radius)
            }
        }
        return builder.buildMesh()
    }

    /// Mean nearest-neighbour distance over a sample of the cloud.
    static func meanSpacing(_ points: [SIMD3<Float>], sample: Int = 400) -> Float? {
        guard points.count >= 2 else { return nil }
        var lo = points[0], hi = points[0]
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let extent = hi - lo
        let volume = max(extent.x, 0.005) * max(extent.y, 0.005) * max(extent.z, 0.005)
        // Density-derived estimate, then refined on a sample with a hash grid.
        let estimate = cbrtf(volume / Float(points.count))
        let grid = Grid(points: points, cell: max(estimate * 2, 1e-3))
        let step = max(points.count / sample, 1)
        var sum: Float = 0
        var counted = 0
        var i = 0
        while i < points.count {
            var best = Float.infinity
            grid.forEachNeighbor(of: points[i]) { j, d2 in
                if j != i, d2 < best { best = d2 }
            }
            if best.isFinite { sum += best.squareRoot(); counted += 1 }
            i += step
        }
        guard counted > 0 else { return nil }
        return sum / Float(counted)
    }

    // MARK: - Front-based mesh growing

    private struct DirectedEdge {
        var u: Int32          // edge is u→v on an existing triangle's boundary
        var v: Int32
        var opposite: Int32   // third vertex of the triangle that owns it
        var ballCenter: SIMD3<Float>
    }

    private struct EdgeKey: Hashable {
        let a: Int32, b: Int32
        init(_ u: Int32, _ v: Int32) { a = min(u, v); b = max(u, v) }
    }

    private struct FrontBuilder {
        let points: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let grid: Grid

        var indices: [UInt32] = []
        var edgeCount: [EdgeKey: Int] = [:]
        var front: [DirectedEdge] = []
        /// Edges that failed to pivot at the current radius; retried at larger radii.
        var boundary: [DirectedEdge] = []
        var hasTriangle: [Bool]
        var seedCursor = 0

        init(points: [SIMD3<Float>], normals: [SIMD3<Float>], grid: Grid) {
            self.points = points
            self.normals = normals
            self.grid = grid
            self.hasTriangle = [Bool](repeating: false, count: points.count)
        }

        mutating func reactivateBoundary() {
            front.append(contentsOf: boundary)
            boundary.removeAll(keepingCapacity: true)
        }

        /// Pops front edges and pivots until the front is exhausted.
        mutating func expandFront(radius: Float) {
            while let edge = front.popLast() {
                guard edgeCount[EdgeKey(edge.u, edge.v)] == 1 else { continue } // became inner
                if let (candidate, center) = pivot(edge: edge, radius: radius) {
                    addTriangle(edge.v, edge.u, candidate, ballCenter: center)
                } else {
                    boundary.append(edge)
                }
            }
        }

        /// Finds one new seed triangle among points not yet meshed. Returns
        /// false when no seed exists (at this radius).
        mutating func seedTriangle(radius: Float) -> Bool {
            while seedCursor < points.count {
                let i = seedCursor
                seedCursor += 1
                guard !hasTriangle[i] else { continue }
                var neighbors: [(index: Int, d2: Float)] = []
                grid.forEachNeighbor(of: points[i]) { j, d2 in
                    if j != i, d2 < radius * radius * 4 { neighbors.append((j, d2)) }
                }
                guard neighbors.count >= 2 else { continue }
                neighbors.sort { $0.d2 < $1.d2 }
                let tryCount = min(neighbors.count, 12)
                for a in 0..<tryCount {
                    for b in (a + 1)..<tryCount {
                        let j = neighbors[a].index, k = neighbors[b].index
                        guard !hasTriangle[j] || !hasTriangle[k] else { continue }
                        guard let center = emptyBallCenter(Int32(i), Int32(j), Int32(k), radius: radius)
                        else { continue }
                        // Orient the seed so its face normal agrees with the points'.
                        let nf = faceNormal(Int32(i), Int32(j), Int32(k))
                        let reference = normals[i] + normals[j] + normals[k]
                        if simd_dot(nf, reference) >= 0 {
                            addTriangle(Int32(i), Int32(j), Int32(k), ballCenter: center)
                        } else {
                            addTriangle(Int32(i), Int32(k), Int32(j), ballCenter: center)
                        }
                        return true
                    }
                }
            }
            // Reset so the next (larger) radius rescans unmeshed points.
            seedCursor = 0
            return false
        }

        /// Classic pivot: rotate the ball around edge (u,v) away from `opposite`
        /// and return the first point it touches (smallest rotation angle).
        private func pivot(edge: DirectedEdge, radius: Float) -> (Int32, SIMD3<Float>)? {
            let a = points[Int(edge.u)], b = points[Int(edge.v)]
            let m = (a + b) * 0.5
            let axisRaw = b - a
            let axisLen = simd_length(axisRaw)
            guard axisLen > 1e-6 else { return nil }
            let axis = axisRaw / axisLen
            var rOld = edge.ballCenter - m
            rOld -= axis * simd_dot(rOld, axis)
            guard simd_length(rOld) > 1e-9 else { return nil }
            let ref = simd_normalize(rOld)
            let refPerp = simd_cross(axis, ref)

            var bestAngle = Float.greatestFiniteMagnitude
            var best: (Int32, SIMD3<Float>)?

            grid.forEachNeighbor(of: m) { c, d2 in
                let candidate = Int32(c)
                guard candidate != edge.u, candidate != edge.v, candidate != edge.opposite,
                      d2 < radius * radius * 4 else { return }
                // Manifold guard: new edges must not already carry two triangles.
                if (edgeCount[EdgeKey(edge.u, candidate)] ?? 0) >= 2 { return }
                if (edgeCount[EdgeKey(edge.v, candidate)] ?? 0) >= 2 { return }
                guard let center = emptyBallCenter(edge.v, edge.u, candidate, radius: radius)
                else { return }
                // Rotation angle of the new ball centre around the edge axis,
                // measured from the old centre, in (0, 2π).
                var rNew = center - m
                rNew -= axis * simd_dot(rNew, axis)
                guard simd_length(rNew) > 1e-9 else { return }
                let dirNew = simd_normalize(rNew)
                var angle = atan2f(simd_dot(dirNew, refPerp), simd_dot(dirNew, ref))
                if angle <= 1e-4 { angle += 2 * .pi }
                // Winding/orientation guard: triangle (v, u, candidate).
                let nf = faceNormal(edge.v, edge.u, candidate)
                let reference = normals[Int(edge.u)] + normals[Int(edge.v)] + normals[Int(candidate)]
                guard simd_dot(nf, reference) > 0 else { return }
                if angle < bestAngle {
                    bestAngle = angle
                    best = (candidate, center)
                }
            }
            return best
        }

        /// Centre of a ρ-ball resting on the three points with no other point
        /// inside, or nil when none exists. Tries both sides of the triangle.
        private func emptyBallCenter(_ i: Int32, _ j: Int32, _ k: Int32,
                                     radius: Float) -> SIMD3<Float>? {
            let p0 = points[Int(i)], p1 = points[Int(j)], p2 = points[Int(k)]
            let e0 = p1 - p0, e1 = p2 - p0
            let normal = simd_cross(e0, e1)
            let nLen2 = simd_length_squared(normal)
            guard nLen2 > 1e-12 else { return nil }
            // Circumcenter via the standard barycentric formula.
            let d00 = simd_length_squared(e0)
            let d11 = simd_length_squared(e1)
            let cc = p0 + (simd_cross(simd_cross(e0, e1), e0) * d11
                           + simd_cross(e1, simd_cross(e0, e1)) * d00) / (2 * nLen2)
            let rc2 = simd_length_squared(cc - p0)
            let h2 = radius * radius - rc2
            guard h2 > 0 else { return nil }
            let h = h2.squareRoot()
            let nUnit = normal / nLen2.squareRoot()

            for sign: Float in [1, -1] {
                let center = cc + nUnit * (h * sign)
                if isBallEmpty(center: center, radius: radius, ignoring: (i, j, k)) {
                    return center
                }
            }
            return nil
        }

        private func isBallEmpty(center: SIMD3<Float>, radius: Float,
                                 ignoring: (Int32, Int32, Int32)) -> Bool {
            let limit = radius * radius * (1 - 1e-3)
            var empty = true
            grid.forEachNeighbor(of: center) { q, _ in
                guard empty else { return }
                let qi = Int32(q)
                if qi == ignoring.0 || qi == ignoring.1 || qi == ignoring.2 { return }
                if simd_distance_squared(points[q], center) < limit { empty = false }
            }
            return empty
        }

        private func faceNormal(_ i: Int32, _ j: Int32, _ k: Int32) -> SIMD3<Float> {
            let a = points[Int(i)]
            return simd_cross(points[Int(j)] - a, points[Int(k)] - a)
        }

        /// Registers triangle (i, j, k) — CCW from outside — and updates the front.
        private mutating func addTriangle(_ i: Int32, _ j: Int32, _ k: Int32,
                                          ballCenter: SIMD3<Float>) {
            indices.append(contentsOf: [UInt32(i), UInt32(j), UInt32(k)])
            hasTriangle[Int(i)] = true; hasTriangle[Int(j)] = true; hasTriangle[Int(k)] = true
            // Directed boundary edges of (i,j,k) are (j,i), (k,j), (i,k): a new
            // triangle attaching to one must reverse it to keep winding consistent.
            register(u: j, v: i, opposite: k, ballCenter: ballCenter)
            register(u: k, v: j, opposite: i, ballCenter: ballCenter)
            register(u: i, v: k, opposite: j, ballCenter: ballCenter)
        }

        private mutating func register(u: Int32, v: Int32, opposite: Int32,
                                       ballCenter: SIMD3<Float>) {
            let key = EdgeKey(u, v)
            let count = (edgeCount[key] ?? 0) + 1
            edgeCount[key] = count
            if count == 1 {
                front.append(DirectedEdge(u: u, v: v, opposite: opposite, ballCenter: ballCenter))
            }
            // count == 2 → inner edge; stale front entries are skipped lazily.
        }

        /// Compacts used vertices into a MeshData with face-accumulated normals.
        func buildMesh() -> MeshData? {
            guard indices.count >= 3 else { return nil }
            var remap = [UInt32: UInt32](minimumCapacity: points.count)
            var vertices: [SIMD3<Float>] = []
            var newIndices: [UInt32] = []
            newIndices.reserveCapacity(indices.count)
            for old in indices {
                if let m = remap[old] {
                    newIndices.append(m)
                } else {
                    let m = UInt32(vertices.count)
                    remap[old] = m
                    vertices.append(points[Int(old)])
                    newIndices.append(m)
                }
            }
            var faceNormals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
            var t = 0
            while t + 2 < newIndices.count {
                let a = Int(newIndices[t]), b = Int(newIndices[t + 1]), c = Int(newIndices[t + 2])
                let nf = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
                faceNormals[a] += nf; faceNormals[b] += nf; faceNormals[c] += nf
                t += 3
            }
            for v in 0..<faceNormals.count {
                let len = simd_length(faceNormals[v])
                faceNormals[v] = len > 1e-9 ? faceNormals[v] / len : SIMD3<Float>(0, 1, 0)
            }
            return MeshData(vertices: vertices, normals: faceNormals, indices: newIndices)
        }
    }

    // MARK: - Spatial hash

    struct Grid {
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

        /// Streams `(index, squaredDistance)` over the 3×3×3 cell block around `p`.
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
