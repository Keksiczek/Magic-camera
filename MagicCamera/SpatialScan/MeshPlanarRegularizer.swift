//
//  MeshPlanarRegularizer.swift
//  Magic Camera
//
//  Flattens the large planar regions of a reconstructed surface — the walls,
//  floor and ceiling of a room scan. A marching-cubes surface fitted to a noisy
//  LiDAR cloud comes out wavy: what should be a flat wall ripples by a few cm, so
//  the model reads as covered in bumps (visible from both sides of the
//  double-sided mesh). Detecting the dominant planes with RANSAC and snapping
//  their inlier vertices exactly onto the plane removes that ripple while leaving
//  any geometry more than `tolerance` off every plane untouched — furniture,
//  relief and organic detail keep their shape.
//
//  A no-op on shapes with no large flat region (a single small object), so it is
//  safe to run unconditionally on the surface path. Pure value math, off-main,
//  unit-testable; the RANSAC uses a seeded generator so results are reproducible.
//

import simd

enum MeshPlanarRegularizer {
    struct Plane { var normal: SIMD3<Float>; var offset: Float }   // n·x = offset, |n| = 1

    /// Snaps inliers of up to `maxPlanes` dominant planes onto those planes.
    /// Returns the regularised mesh, how many planes were flattened (0 = the input
    /// was returned unchanged), and the distance tolerance actually used.
    ///
    /// - tolerance: max distance (m) a vertex may sit from a plane to be snapped.
    ///   `nil` (the default) derives it from the scan's overall size — a room keeps
    ///   a tight ~2.5 cm, a large outdoor building relaxes toward ~9 cm. LiDAR noise
    ///   grows with distance, so on a big scan the far walls ripple far past a fixed
    ///   2.5 cm; a fixed tolerance then finds too few inliers and *rejects* the wall,
    ///   leaving it faceted. Scaling the tolerance to the scan lets those walls flatten.
    /// - minInlierFraction: a plane must claim at least this share of the *welded*
    ///   vertices to count — keeps small coincidental planes from being flattened.
    ///   A multi-wall building splits its area across many faces, so each wall is a
    ///   smaller share than a room's floor: the fraction is deliberately low.
    static func regularize(_ input: MeshData,
                           tolerance: Float? = nil,
                           minInlierFraction: Float = 0.04,
                           maxPlanes: Int = 12,
                           iterations: Int = 200) -> (mesh: MeshData, planes: Int, tolerance: Float) {
        let mesh = input.weldingDuplicateVertices()
        let n = mesh.vertices.count
        let tol = tolerance ?? adaptiveTolerance(mesh.vertices)
        guard n >= 100, mesh.indices.count >= 3 else { return (input, 0, tol) }

        var verts = mesh.vertices
        var assigned = [Bool](repeating: false, count: n)
        let minInliers = max(Int(Float(n) * minInlierFraction), 150)
        var rng = SeededGenerator(seed: 0x9E37_79B9_7F4A_7C15)
        var planesFound = 0

        for _ in 0..<maxPlanes {
            var pool: [Int] = []
            pool.reserveCapacity(n)
            for i in 0..<n where !assigned[i] { pool.append(i) }
            guard pool.count >= minInliers else { break }

            guard let plane = bestPlane(verts, normals: mesh.normals, pool: pool,
                                        tolerance: tol, iterations: iterations,
                                        minInliers: minInliers, rng: &rng) else { break }

            // Collect the inliers, refit the plane to all of them (a far better fit
            // than the 3-point seed), then snap each inlier exactly onto it.
            let inliers = pool.filter { abs(signedDistance(verts[$0], plane)) <= tol }
            guard inliers.count >= minInliers else { break }
            let refined = fitPlane(verts, inliers) ?? plane
            for i in inliers {
                verts[i] = project(verts[i], onto: refined)
                assigned[i] = true
            }
            planesFound += 1
        }

        guard planesFound > 0 else { return (input, 0, tol) }
        let normals = recomputeNormals(vertices: verts, indices: mesh.indices)
        return (MeshData(vertices: verts, normals: normals,
                         indices: mesh.indices, classifications: mesh.classifications),
                planesFound, tol)
    }

    /// Distance tolerance scaled to the scan's overall size (bounding-box
    /// diagonal): ~2.5 cm at room scale, growing toward 9 cm on a large building so
    /// distant, noisier walls still register as planes. Clamped both ends — the
    /// ceiling also guards against a stray far speck inflating the box. These bounds
    /// are the primary device-tuning lever for how aggressively walls flatten.
    static func adaptiveTolerance(_ verts: [SIMD3<Float>]) -> Float {
        guard let first = verts.first else { return 0.025 }
        var lo = first, hi = first
        for v in verts { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        let diagonal = simd_length(hi - lo)
        return min(max(diagonal * 0.004, 0.025), 0.09)
    }

    // MARK: - Plane geometry

    static func signedDistance(_ p: SIMD3<Float>, _ plane: Plane) -> Float {
        simd_dot(plane.normal, p) - plane.offset
    }

    private static func project(_ p: SIMD3<Float>, onto plane: Plane) -> SIMD3<Float> {
        p - plane.normal * signedDistance(p, plane)
    }

    // MARK: - RANSAC

    /// Best plane (most inliers, ties broken by first found) over `iterations`
    /// samples; nil if none reaches `minInliers`. Inlier counting is strided on
    /// large pools so the search stays cheap on a dense mesh.
    ///
    /// Each sample seeds the candidate plane from a single random vertex and its
    /// surface normal, not three random vertices. Three-random-point RANSAC needs
    /// all three to land on the *same* wall — its odds fall as the cube of that
    /// wall's share, so on a building with many walls it reliably seeds only the
    /// one or two biggest and misses the rest (the "planes 1" symptom on a large
    /// scan). A point + its normal names a plane directly, so any vertex on a wall
    /// seeds that wall; a noisy seed is fine because the winner is refit to all its
    /// inliers afterwards. Falls back to a 3-point sample when normals are absent.
    private static func bestPlane(_ verts: [SIMD3<Float>], normals: [SIMD3<Float>],
                                  pool: [Int], tolerance: Float, iterations: Int,
                                  minInliers: Int, rng: inout SeededGenerator) -> Plane? {
        let m = pool.count
        guard m >= 3 else { return nil }
        // Score against a capped, evenly-strided subset, then scale the count back
        // up — keeps RANSAC O(iterations · 20k) instead of O(iterations · m).
        let scoreCap = 20_000
        let stride = max(m / scoreCap, 1)
        let scored = stride == 1 ? pool : Swift.stride(from: 0, to: m, by: stride).map { pool[$0] }
        let scaleBack = Float(m) / Float(scored.count)
        let minScored = Int(Float(minInliers) / scaleBack)
        let haveNormals = normals.count == verts.count

        var best: Plane?
        var bestCount = minScored - 1
        for _ in 0..<iterations {
            let anchor = pool[Int(rng.next(upTo: UInt64(m)))]
            let plane: Plane
            if haveNormals, simd_length(normals[anchor]) > 0.5 {
                let nrm = simd_normalize(normals[anchor])
                plane = Plane(normal: nrm, offset: simd_dot(nrm, verts[anchor]))
            } else {
                let a = verts[anchor]
                let b = verts[pool[Int(rng.next(upTo: UInt64(m)))]]
                let c = verts[pool[Int(rng.next(upTo: UInt64(m)))]]
                let cross = simd_cross(b - a, c - a)
                let len = simd_length(cross)
                guard len > 1e-9 else { continue }
                plane = Plane(normal: cross / len, offset: simd_dot(cross / len, a))
            }
            var count = 0
            for idx in scored where abs(signedDistance(verts[idx], plane)) <= tolerance { count += 1 }
            if count > bestCount { bestCount = count; best = plane }
        }
        return best
    }

    /// Least-squares plane through `indices`: centroid + the eigenvector of the
    /// covariance with the smallest eigenvalue (the surface normal). Found by two
    /// power iterations for the dominant in-plane axes, then their cross product —
    /// stable even when the data is perfectly flat (a singular covariance).
    static func fitPlane(_ verts: [SIMD3<Float>], _ indices: [Int]) -> Plane? {
        guard indices.count >= 3 else { return nil }
        var centroid = SIMD3<Float>.zero
        for i in indices { centroid += verts[i] }
        centroid /= Float(indices.count)

        var c = simd_float3x3(0)
        for i in indices {
            let d = verts[i] - centroid
            c.columns.0 += d * d.x
            c.columns.1 += d * d.y
            c.columns.2 += d * d.z
        }
        let e1 = dominantEigenvector(c, seed: SIMD3<Float>(1, 0, 0))
        // Deflate the dominant axis, take the next: the two in-plane directions.
        let lambda1 = simd_dot(e1, c * e1)
        var d = c
        d.columns.0 -= e1 * (lambda1 * e1.x)
        d.columns.1 -= e1 * (lambda1 * e1.y)
        d.columns.2 -= e1 * (lambda1 * e1.z)
        let e2 = dominantEigenvector(d, seed: SIMD3<Float>(0, 1, 0))
        let normalRaw = simd_cross(e1, e2)
        let len = simd_length(normalRaw)
        guard len > 1e-9 else { return nil }
        let normal = normalRaw / len
        return Plane(normal: normal, offset: simd_dot(normal, centroid))
    }

    private static func dominantEigenvector(_ m: simd_float3x3, seed: SIMD3<Float>) -> SIMD3<Float> {
        var v = seed
        for _ in 0..<24 {
            let next = m * v
            let len = simd_length(next)
            if len < 1e-12 { return v }
            v = next / len
        }
        return v
    }

    private static func recomputeNormals(vertices: [SIMD3<Float>],
                                         indices: [UInt32]) -> [SIMD3<Float>] {
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

/// Tiny SplitMix64 — a deterministic generator so RANSAC results are reproducible
/// (stable output across runs, testable off-device).
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<bound (bound > 0).
    mutating func next(upTo bound: UInt64) -> UInt64 { bound == 0 ? 0 : next() % bound }
}
