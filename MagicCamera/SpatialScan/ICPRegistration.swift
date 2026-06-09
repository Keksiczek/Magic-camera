//
//  ICPRegistration.swift
//  Magic Camera
//
//  Iterative Closest Point registration for merging two point clouds captured
//  separately (different ARKit world frames). To tolerate gross orientation
//  differences it tries a few coarse rotation seeds, centroid-aligns each, then
//  refines with point-to-point ICP (Horn's quaternion method, top eigenvector via
//  shifted power iteration) and keeps the best fit. Nearest neighbours come from a
//  spatial hash. Pure value-type math, ARKit-free and off-main-thread friendly.
//

import simd

enum ICPRegistration {

    // MARK: - Public

    struct MergeResult {
        let cloud: PointCloud
        let fitness: Float   // 0…1, fraction of the new scan that overlapped the base
    }

    /// Aligns `newScan` onto `base`, appends it, and voxel-downsamples the union.
    static func merge(newScan: PointCloud, into base: PointCloud,
                      voxelSize: Float = 0.01) -> MergeResult {
        guard !base.isEmpty else { return MergeResult(cloud: newScan, fitness: 0) }
        guard !newScan.isEmpty else { return MergeResult(cloud: base, fitness: 0) }

        let registration = register(source: newScan, target: base)
        var combined = base
        for i in 0..<newScan.count {
            combined.append(position: transformPoint(registration.transform, newScan.positions[i]),
                            color: newScan.colors[i], confidence: newScan.confidences[i])
        }
        return MergeResult(cloud: voxelDownsample(combined, voxelSize: voxelSize),
                           fitness: registration.fitness)
    }

    struct Registration {
        let transform: simd_float4x4
        let fitness: Float   // fraction of sampled source points with a match
        let rmse: Float
    }

    /// Best rigid transform mapping `source` into `target`'s frame.
    static func register(source: PointCloud, target: PointCloud) -> Registration {
        guard source.count >= 4, target.count >= 4 else {
            return Registration(transform: matrix_identity_float4x4, fitness: 0, rmse: .infinity)
        }
        let maxCorrespondence: Float = 0.08
        let grid = HashGrid(points: target.positions, cell: maxCorrespondence)
        let sample = subsample(source.positions, cap: 4000)

        let centroidSource = centroid(source.positions)
        let centroidTarget = centroid(target.positions)

        var best = Registration(transform: matrix_identity_float4x4, fitness: -1, rmse: .infinity)
        for seed in coarseSeeds {
            let initial = makeTransform(rotation: seed,
                                        translation: centroidTarget - seed * centroidSource)
            let refined = refine(sample: sample, target: target.positions, grid: grid,
                                 initial: initial, maxDist: maxCorrespondence)
            if refined.fitness > best.fitness
                || (refined.fitness == best.fitness && refined.rmse < best.rmse) {
                best = refined
            }
        }
        return best
    }

    // MARK: - ICP refinement

    private static func refine(sample: [SIMD3<Float>], target: [SIMD3<Float>],
                               grid: HashGrid, initial: simd_float4x4,
                               maxDist: Float, maxIterations: Int = 24) -> Registration {
        let maxDist2 = maxDist * maxDist
        var transform = initial
        var current = sample.map { transformPoint(initial, $0) }
        var matched = 0
        var rmse: Float = .infinity

        for _ in 0..<maxIterations {
            var src: [SIMD3<Float>] = []
            var dst: [SIMD3<Float>] = []
            src.reserveCapacity(current.count)
            dst.reserveCapacity(current.count)
            var sumSq: Float = 0
            for p in current {
                if let idx = grid.nearest(to: p, in: target, maxDist2: maxDist2) {
                    src.append(p)
                    dst.append(target[idx])
                    sumSq += simd_distance_squared(p, target[idx])
                }
            }
            matched = src.count
            guard matched >= 6 else { break }
            rmse = (sumSq / Float(matched)).squareRoot()

            let step = bestRigidTransform(from: src, to: dst)
            transform = step * transform
            current = current.map { transformPoint(step, $0) }
            if isNearIdentity(step) { break }
        }

        let fitness = sample.isEmpty ? 0 : Float(matched) / Float(sample.count)
        return Registration(transform: transform, fitness: fitness, rmse: rmse)
    }

    // MARK: - Horn's quaternion rigid transform

    static func bestRigidTransform(from src: [SIMD3<Float>],
                                   to dst: [SIMD3<Float>]) -> simd_float4x4 {
        let n = min(src.count, dst.count)
        guard n >= 3 else { return matrix_identity_float4x4 }
        let srcMean = centroid(Array(src[0..<n]))
        let dstMean = centroid(Array(dst[0..<n]))

        var sxx: Float = 0, sxy: Float = 0, sxz: Float = 0
        var syx: Float = 0, syy: Float = 0, syz: Float = 0
        var szx: Float = 0, szy: Float = 0, szz: Float = 0
        for i in 0..<n {
            let s = src[i] - srcMean
            let d = dst[i] - dstMean
            sxx += s.x * d.x; sxy += s.x * d.y; sxz += s.x * d.z
            syx += s.y * d.x; syy += s.y * d.y; syz += s.y * d.z
            szx += s.z * d.x; szy += s.z * d.y; szz += s.z * d.z
        }

        // Horn's symmetric 4x4 N, eigenvector of the largest eigenvalue = quaternion.
        let N: [[Float]] = [
            [sxx + syy + szz, syz - szy,        szx - sxz,        sxy - syx],
            [syz - szy,       sxx - syy - szz,  sxy + syx,        szx + sxz],
            [szx - sxz,       sxy + syx,       -sxx + syy - szz,  syz + szy],
            [sxy - syx,       szx + sxz,        syz + szy,       -sxx - syy + szz]
        ]
        let q = largestEigenvector4(N)
        let rotation = rotationMatrix(fromQuaternion: q)
        return makeTransform(rotation: rotation, translation: dstMean - rotation * srcMean)
    }

    /// Top eigenvector of a symmetric 4x4 via shifted power iteration. Shifting by
    /// the absolute row-sum makes the matrix positive definite, so the dominant
    /// eigenvector is the one of the most-positive eigenvalue (the optimal quat).
    private static func largestEigenvector4(_ M: [[Float]]) -> SIMD4<Float> {
        var shift: Float = 0
        for r in 0..<4 { for c in 0..<4 { shift += abs(M[r][c]) } }
        var A = M
        for i in 0..<4 { A[i][i] += shift }

        var v = SIMD4<Float>(1, 0, 0, 0)
        for _ in 0..<80 {
            let w = SIMD4<Float>(
                A[0][0] * v[0] + A[0][1] * v[1] + A[0][2] * v[2] + A[0][3] * v[3],
                A[1][0] * v[0] + A[1][1] * v[1] + A[1][2] * v[2] + A[1][3] * v[3],
                A[2][0] * v[0] + A[2][1] * v[1] + A[2][2] * v[2] + A[2][3] * v[3],
                A[3][0] * v[0] + A[3][1] * v[1] + A[3][2] * v[2] + A[3][3] * v[3])
            let len = simd_length(w)
            guard len > 1e-12 else { break }
            v = w / len
        }
        return v   // (w, x, y, z)
    }

    private static func rotationMatrix(fromQuaternion q: SIMD4<Float>) -> simd_float3x3 {
        let len = simd_length(q)
        guard len > 1e-12 else { return matrix_identity_float3x3 }
        let n = q / len
        let w = n[0], x = n[1], y = n[2], z = n[3]
        return simd_float3x3(
            SIMD3<Float>(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
            SIMD3<Float>(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
            SIMD3<Float>(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)))
    }

    // MARK: - Helpers

    /// Coarse rotation seeds: identity and 180° flips about each axis, so a scan
    /// captured "the other way round" can still register.
    private static let coarseSeeds: [simd_float3x3] = [
        matrix_identity_float3x3,
        simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, -1)),  // 180° X
        simd_float3x3(SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1)),  // 180° Y
        simd_float3x3(SIMD3(-1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1))   // 180° Z
    ]

    private static func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        var sum = SIMD3<Float>.zero
        for p in points { sum += p }
        return sum / Float(points.count)
    }

    private static func subsample(_ points: [SIMD3<Float>], cap: Int) -> [SIMD3<Float>] {
        guard points.count > cap else { return points }
        let stride = points.count / cap
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(cap)
        var i = 0
        while i < points.count { out.append(points[i]); i += stride }
        return out
    }

    static func transformPoint(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(p, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    private static func makeTransform(rotation: simd_float3x3,
                                      translation: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(rotation.columns.0, 0),
            SIMD4<Float>(rotation.columns.1, 0),
            SIMD4<Float>(rotation.columns.2, 0),
            SIMD4<Float>(translation, 1))
    }

    private static func isNearIdentity(_ m: simd_float4x4) -> Bool {
        let t = m.columns.3
        let translation = SIMD3<Float>(t.x, t.y, t.z)
        let trace = m.columns.0.x + m.columns.1.y + m.columns.2.z
        let angle = acos(min(max((trace - 1) * 0.5, -1), 1))
        return simd_length(translation) < 1e-4 && angle < 1e-3
    }

    private static func voxelDownsample(_ cloud: PointCloud, voxelSize: Float) -> PointCloud {
        var grid = VoxelGrid(voxelSize: voxelSize)
        var out = PointCloud()
        for i in 0..<cloud.count where grid.insert(cloud.positions[i]) {
            out.append(position: cloud.positions[i], color: cloud.colors[i],
                       confidence: cloud.confidences[i])
        }
        return out
    }

    // MARK: - Spatial hash for nearest-neighbour queries

    private struct HashGrid {
        let cell: Float
        private var buckets: [SIMD3<Int32>: [Int]] = [:]

        init(points: [SIMD3<Float>], cell: Float) {
            self.cell = max(cell, 1e-4)
            buckets.reserveCapacity(points.count)
            for (i, p) in points.enumerated() {
                buckets[key(p), default: []].append(i)
            }
        }

        private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            SIMD3<Int32>(Int32((p.x / cell).rounded(.down)),
                         Int32((p.y / cell).rounded(.down)),
                         Int32((p.z / cell).rounded(.down)))
        }

        func nearest(to p: SIMD3<Float>, in points: [SIMD3<Float>], maxDist2: Float) -> Int? {
            let k = key(p)
            var best = -1
            var bestD2 = maxDist2
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let nk = SIMD3<Int32>(k.x &+ Int32(dx), k.y &+ Int32(dy), k.z &+ Int32(dz))
                        guard let bucket = buckets[nk] else { continue }
                        for idx in bucket {
                            let d2 = simd_distance_squared(points[idx], p)
                            if d2 < bestD2 { bestD2 = d2; best = idx }
                        }
                    }
                }
            }
            return best >= 0 ? best : nil
        }
    }
}
