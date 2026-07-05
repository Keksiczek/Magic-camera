//
//  PointCloud.swift
//  Magic Camera
//
//  Plain value type holding the accumulated scan points (position + colour +
//  confidence), plus a voxel grid used to bound density and to support a cheap
//  neighbour-occupancy outlier filter. ARKit-free, so it is unit-testable.
//

import Foundation
import simd

struct PointCloud: Sendable {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var colors: [SIMD3<Float>] = []       // linear-ish RGB 0...1
    private(set) var confidences: [Float] = []         // 0, 0.5, 1.0

    var count: Int { positions.count }
    var isEmpty: Bool { positions.isEmpty }

    mutating func append(position: SIMD3<Float>, color: SIMD3<Float>, confidence: Float) {
        positions.append(position)
        colors.append(color)
        confidences.append(confidence)
    }

    /// Rewrites one point in place — used by the recorder's voxel fusion to
    /// refine a stored point as more depth samples of the same voxel arrive.
    mutating func update(at index: Int, position: SIMD3<Float>,
                         color: SIMD3<Float>, confidence: Float) {
        positions[index] = position
        colors[index] = color
        confidences[index] = confidence
    }

    mutating func reserveCapacity(_ capacity: Int) {
        positions.reserveCapacity(capacity)
        colors.reserveCapacity(capacity)
        confidences.reserveCapacity(capacity)
    }

    mutating func removeAll() {
        positions.removeAll(keepingCapacity: true)
        colors.removeAll(keepingCapacity: true)
        confidences.removeAll(keepingCapacity: true)
    }

    /// A strided subset with at most `maxCount` points — used to keep the live
    /// scan overlay cheap to rebuild as the full cloud grows into the millions.
    func downsampled(maxCount: Int) -> PointCloud {
        let n = positions.count
        guard maxCount > 0, n > maxCount else { return self }
        let step = (n + maxCount - 1) / maxCount
        var out = PointCloud()
        out.reserveCapacity(n / step + 1)
        var i = 0
        while i < n {
            out.append(position: positions[i], color: colors[i], confidence: confidences[i])
            i += step
        }
        return out
    }

    /// A copy keeping only `indices` (in the given order) — used to carry a
    /// cloud and its index-aligned aux arrays through the same subsample.
    func subset(_ indices: [Int]) -> PointCloud {
        var out = PointCloud()
        out.reserveCapacity(indices.count)
        for i in indices where i >= 0 && i < positions.count {
            out.append(position: positions[i], color: colors[i], confidence: confidences[i])
        }
        return out
    }

    /// Indices of points whose (fused) confidence is at least `minConfidence`.
    /// Used to drop the bleed/ghost survivors that carving missed before
    /// reconstruction; returns indices so index-aligned aux arrays (normals,
    /// view rays) can follow the same subsample.
    func confidentIndices(min minConfidence: Float) -> [Int] {
        var kept: [Int] = []
        kept.reserveCapacity(count)
        for i in 0..<count where confidences[i] >= minConfidence { kept.append(i) }
        return kept
    }

    /// Indices of one representative point per reconstruction voxel (half the
    /// mesh cell for the given lattice `resolution`), coarsening further until
    /// the kept set fits under `maxPoints`. Returns indices so index-aligned aux
    /// arrays (normals, view rays) can follow the same subsample.
    ///
    /// Reconstruction only needs ~one point per half-cell; feeding a
    /// million-point room scan straight into normal estimation and the signed
    /// field is what pushed the off-main job past the CPU/memory watchdog (a
    /// 90 s / 1.2 GB cpu_resource kill). Bounding here keeps the surface
    /// essentially identical while making the work finite, and dropping under
    /// 400 k also re-enables consistent normal orientation for cleaner output.
    /// Small dense scans (a coin at 2 mm) stay under the cap and keep every
    /// point; the caller keeps the full-res cloud as the colour source, so
    /// texture detail is unaffected.
    func reconstructionSampleIndices(resolution: Int, maxPoints: Int = 350_000) -> [Int] {
        let n = positions.count
        guard n > maxPoints, let box = boundingBox() else { return Array(0..<n) }
        let extent = box.max - box.min
        let maxExtent = max(max(extent.x, extent.y), extent.z)
        guard maxExtent > 0 else { return Array(0..<n) }
        let origin = box.min
        var voxel = max(maxExtent / Float(max(resolution, 16)) * 0.5, 1e-4)
        var kept: [Int] = []
        kept.reserveCapacity(maxPoints + 1)
        for _ in 0..<16 {
            var seen = Set<SIMD3<Int32>>()
            seen.reserveCapacity(min(n, maxPoints * 2))
            kept.removeAll(keepingCapacity: true)
            for i in 0..<n {
                let s = (positions[i] - origin) / voxel
                let key = SIMD3<Int32>(Int32(s.x.rounded(.down)),
                                       Int32(s.y.rounded(.down)),
                                       Int32(s.z.rounded(.down)))
                if seen.insert(key).inserted { kept.append(i) }
            }
            if kept.count <= maxPoints { break }
            voxel *= 1.6   // still too dense — coarsen and retry
        }
        return kept
    }

    func boundingBox() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = positions.first else { return nil }
        var lo = first, hi = first
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    func centroid() -> SIMD3<Float> {
        guard !positions.isEmpty else { return .zero }
        var sum = SIMD3<Float>.zero
        for p in positions { sum += p }
        return sum / Float(positions.count)
    }

    /// Affinely transformed copy — positions through the full matrix, colours
    /// and confidences carried over. Used by the Studio scale/rotate tools.
    func transformed(by transform: simd_float4x4) -> PointCloud {
        var out = PointCloud()
        out.reserveCapacity(count)
        for i in 0..<count {
            let world = transform * SIMD4<Float>(positions[i], 1)
            out.append(position: SIMD3<Float>(world.x, world.y, world.z),
                       color: colors[i], confidence: confidences[i])
        }
        return out
    }
}

/// Tracks which voxels are occupied so we keep at most one point per voxel — a
/// cheap spatial downsample that bounds memory and enables outlier filtering.
struct VoxelGrid {
    let voxelSize: Float
    private var occupied: Set<SIMD3<Int32>> = []

    init(voxelSize: Float) {
        self.voxelSize = max(voxelSize, 0.0001)
    }

    private func key(for position: SIMD3<Float>) -> SIMD3<Int32> {
        let scaled = position / voxelSize
        return SIMD3<Int32>(Int32(scaled.x.rounded(.down)),
                            Int32(scaled.y.rounded(.down)),
                            Int32(scaled.z.rounded(.down)))
    }

    mutating func insert(_ position: SIMD3<Float>) -> Bool {
        occupied.insert(key(for: position)).inserted
    }

    /// Number of occupied voxels in the 3x3x3 block around `position`
    /// (includes the point's own cell, so an isolated point returns 1).
    func occupiedNeighborCount(of position: SIMD3<Float>) -> Int {
        let k = key(for: position)
        var count = 0
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let neighbor = SIMD3<Int32>(k.x &+ Int32(dx), k.y &+ Int32(dy), k.z &+ Int32(dz))
                    if occupied.contains(neighbor) { count += 1 }
                }
            }
        }
        return count
    }

    /// Whether the 3x3x3 block around `position` holds at least `minOccupied`
    /// occupied cells (counting the point's own). Early-exits, so a point in a
    /// dense region costs ~1–2 set lookups instead of the full 27 — the common
    /// case during outlier filtering on a million-point cloud.
    func hasOccupiedNeighbors(of position: SIMD3<Float>, atLeast minOccupied: Int) -> Bool {
        guard minOccupied > 0 else { return true }
        let k = key(for: position)
        var count = 0
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let neighbor = SIMD3<Int32>(k.x &+ Int32(dx), k.y &+ Int32(dy), k.z &+ Int32(dz))
                    if occupied.contains(neighbor) {
                        count += 1
                        if count >= minOccupied { return true }
                    }
                }
            }
        }
        return false
    }

    var occupiedCount: Int { occupied.count }

    mutating func reset() { occupied.removeAll(keepingCapacity: true) }
}

/// Per-point surface-normal estimation via local PCA. For each point, the
/// covariance of its `k` nearest neighbours is eigen-decomposed (Jacobi); the
/// eigenvector of the smallest eigenvalue is the surface normal. Normals are
/// flipped to face a reference direction (a supplied viewpoint, or outward from
/// the cloud centroid by default) so they are roughly consistent. Pure value
/// math, ARKit-free and off-main-thread friendly — feeds normal-aware export
/// (PLY) and downstream reconstruction.
enum PointCloudNormals {
    static func estimate(_ cloud: PointCloud,
                         neighbors k: Int = 12,
                         viewpoint: SIMD3<Float>? = nil) -> [SIMD3<Float>] {
        let n = cloud.count
        let fallback = SIMD3<Float>(0, 1, 0)
        guard n >= 3, let box = cloud.boundingBox() else {
            return [SIMD3<Float>](repeating: fallback, count: n)
        }
        // Cell ≈ twice the average spacing so a 3×3×3 search yields enough neighbours.
        let extent = box.max - box.min
        let volume = max(extent.x, 0.01) * max(extent.y, 0.01) * max(extent.z, 0.01)
        let cell = max(cbrtf(volume / Float(n)) * 2, 0.005)
        let grid = NeighborGrid(points: cloud.positions, cell: cell)
        let centroid = cloud.centroid()

        var normals = [SIMD3<Float>](repeating: fallback, count: n)
        // Each point's PCA is independent and the grid is read-only after init,
        // so fan the per-point work across all cores (each writes its own slot).
        normals.withUnsafeMutableBufferPointer { buffer in
            // Safe to share across the parallel loop: every iteration writes a
            // distinct slot `base[i]`, so there is no overlapping access.
            nonisolated(unsafe) let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { i in
                let p = cloud.positions[i]
                let idx = grid.nearest(to: p, in: cloud.positions, k: k)
                guard idx.count >= 3 else { return }   // leaves the fallback normal

                var mean = SIMD3<Float>.zero
                for j in idx { mean += cloud.positions[j] }
                mean /= Float(idx.count)

                // Symmetric covariance matrix accumulated as its 6 unique entries.
                var xx: Float = 0, xy: Float = 0, xz: Float = 0
                var yy: Float = 0, yz: Float = 0, zz: Float = 0
                for j in idx {
                    let d = cloud.positions[j] - mean
                    xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
                    yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
                }
                var normal = smallestEigenvector(xx: xx, xy: xy, xz: xz, yy: yy, yz: yz, zz: zz)

                // Orient toward the viewpoint (away from the surface interior);
                // without a viewpoint, orient outward from the centroid — a sane
                // default for objects.
                let reference = (viewpoint.map { $0 - p }) ?? (p - centroid)
                if simd_dot(normal, reference) < 0 { normal = -normal }
                base[i] = normal
            }
        }
        return normals
    }

    /// Estimates normals and then orients them *consistently* across the
    /// surface (Hoppe-style): PCA gives an unsigned normal per point, and a
    /// minimum-spanning-tree flood-fill over the k-NN graph propagates a single
    /// coherent side. Per-point viewpoint/centroid flips leave neighbouring
    /// normals disagreeing across concavities, which makes ball-pivot and the
    /// signed-field smooth reconstruction tear or pock; consistent orientation
    /// fixes that. Use for reconstruction; PLY export keeps the cheaper estimate.
    static func estimateConsistent(_ cloud: PointCloud, neighbors k: Int = 12) -> [SIMD3<Float>] {
        orientConsistently(estimate(cloud, neighbors: k),
                           positions: cloud.positions, neighbors: min(k, 10))
    }

    /// Flips `normals` so neighbours agree, propagating orientation along the
    /// MST of the k-NN graph (edge weight = 1 − |nᵢ·nⱼ|, so the tree routes
    /// through the flattest, most reliable transitions). Each connected
    /// component is seeded at its topmost point, oriented outward from the
    /// centroid. Above `maxPoints` the MST is skipped (cost guard) and the input
    /// is returned unchanged.
    static func orientConsistently(_ normals: [SIMD3<Float>], positions: [SIMD3<Float>],
                                   neighbors k: Int = 10,
                                   maxPoints: Int = 400_000) -> [SIMD3<Float>] {
        let n = normals.count
        guard n == positions.count, n >= 3, n <= maxPoints else { return normals }

        var lo = positions[0], hi = positions[0]
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let extent = hi - lo
        let volume = max(extent.x, 0.01) * max(extent.y, 0.01) * max(extent.z, 0.01)
        let cell = max(cbrtf(volume / Float(n)) * 2, 0.005)
        let grid = NeighborGrid(points: positions, cell: cell)
        var centroid = SIMD3<Float>.zero
        for p in positions { centroid += p }
        centroid /= Float(n)

        var working = normals
        var inTree = [Bool](repeating: false, count: n)
        var dist = [Float](repeating: .greatestFiniteMagnitude, count: n)
        var parent = [Int](repeating: -1, count: n)
        var heap = OrientHeap()
        var remaining = n
        // Forward cursor for the next component's seed. A fresh O(n) scan for the
        // topmost unvisited point per component made this O(n²) on fragmented or
        // sparse clouds — isolated points whose neighbours fall outside the 3×3×3
        // grid block become singleton components, so a 35 k-point Build Surface
        // spent ~160 s here. The cursor only advances (every index below it is
        // already in the tree), so seeding all components is O(n) total. Seeding
        // at the first unvisited point instead of the topmost is behaviour-
        // preserving: each seed's sign is coerced outward-from-centroid below and
        // propagated along the MST regardless of which point starts the component.
        var nextSeed = 0

        while remaining > 0 {
            while nextSeed < n && inTree[nextSeed] { nextSeed += 1 }
            guard nextSeed < n else { break }
            let seed = nextSeed
            if simd_dot(working[seed], positions[seed] - centroid) < 0 { working[seed] = -working[seed] }
            dist[seed] = 0; parent[seed] = -1
            heap.push(0, seed)

            while let (_, u) = heap.pop() {
                if inTree[u] { continue }
                inTree[u] = true; remaining -= 1
                let p = parent[u]
                if p >= 0, simd_dot(working[u], working[p]) < 0 { working[u] = -working[u] }
                for v in grid.nearest(to: positions[u], in: positions, k: k) where !inTree[v] {
                    let w = 1 - abs(simd_dot(working[u], working[v]))
                    if w < dist[v] { dist[v] = w; parent[v] = u; heap.push(w, v) }
                }
            }
        }
        return working
    }

    /// Eigenvector of the smallest eigenvalue of a symmetric 3×3 matrix, via a
    /// compact cyclic Jacobi rotation. Robust for the tiny matrices used here.
    private static func smallestEigenvector(xx: Float, xy: Float, xz: Float,
                                            yy: Float, yz: Float, zz: Float) -> SIMD3<Float> {
        var a = [[xx, xy, xz], [xy, yy, yz], [xz, yz, zz]]
        var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

        for _ in 0..<24 {
            // Largest off-diagonal magnitude picks the rotation plane (p, q).
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
            for r in 0..<3 {
                let vrp = v[r][p], vrq = v[r][q]
                v[r][p] = c * vrp - s * vrq
                v[r][q] = s * vrp + c * vrq
            }
        }

        // Eigenvalues sit on the diagonal; the smallest one's eigenvector is column m.
        var m = 0
        if a[1][1] < a[m][m] { m = 1 }
        if a[2][2] < a[m][m] { m = 2 }
        let normal = SIMD3<Float>(v[0][m], v[1][m], v[2][m])
        let length = simd_length(normal)
        return length > 1e-6 ? normal / length : SIMD3<Float>(0, 1, 0)
    }

    /// Uniform spatial hash returning the indices of the `k` nearest points within
    /// the 3×3×3 block around a query (cheap approximate k-NN, like the denoiser).
    private struct NeighborGrid {
        let cell: Float
        private var buckets: [SIMD3<Int32>: [Int]] = [:]

        init(points: [SIMD3<Float>], cell: Float) {
            self.cell = max(cell, 1e-4)
            buckets.reserveCapacity(points.count)
            for (i, p) in points.enumerated() { buckets[key(p), default: []].append(i) }
        }

        private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
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

/// Minimal binary min-heap of (key, node) for the normal-orientation MST
/// (Prim with lazy deletion). File-scope so the value type stays simple.
private struct OrientHeap {
    private var keys: [Float] = []
    private var nodes: [Int] = []

    mutating func push(_ key: Float, _ node: Int) {
        keys.append(key); nodes.append(node)
        var i = nodes.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if keys[parent] <= keys[i] { break }
            keys.swapAt(parent, i); nodes.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> (Float, Int)? {
        guard !nodes.isEmpty else { return nil }
        let topKey = keys[0], topNode = nodes[0]
        let lastKey = keys.removeLast(), lastNode = nodes.removeLast()
        if !nodes.isEmpty {
            keys[0] = lastKey; nodes[0] = lastNode
            var i = 0
            let count = nodes.count
            while true {
                var smallest = i
                let l = 2 * i + 1, r = 2 * i + 2
                if l < count, keys[l] < keys[smallest] { smallest = l }
                if r < count, keys[r] < keys[smallest] { smallest = r }
                if smallest == i { break }
                keys.swapAt(smallest, i); nodes.swapAt(smallest, i)
                i = smallest
            }
        }
        return (topKey, topNode)
    }
}
