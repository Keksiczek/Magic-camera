//
//  FrameToModelICP.swift
//  Magic Camera
//
//  Per-frame frame-to-model registration. ARKit's world pose is excellent but
//  not millimetre-exact: consecutive fused frames land ±1–2 cm apart (measured
//  ~16 mm local-plane RMS on device clouds), which is what reads as crinkled
//  walls, drift-doubled object orbits, wavy ceramic edges and shattered UV
//  charts. Before a frame's depth is fused, a damped point-to-plane ICP aligns
//  the frame to the model accumulated so far — the model is the fused average
//  of every previous frame, so it is the most stable reference available.
//
//  The solver is deliberately conservative: it starts from the ARKit pose,
//  Tikhonov-damps the 6-DoF Gauss–Newton step toward that prior (so degenerate
//  geometry — a single wall filling the view — takes the well-constrained
//  normal component and leaves the unconstrained tangential/rotational
//  components at ARKit's answer), trims gross-residual correspondences (moved
//  objects, passers-by), and reports the correction magnitude so the caller
//  can reject anything beyond frame-jitter scale. Pure value math: no ARKit,
//  no Metal — unit-testable on any platform.
//

import simd

enum FrameToModelICP {

    /// One matched pair: a frame point (with the running correction already
    /// applied), the model point it matched, and the model's surface normal
    /// there (unit length, oriented toward the camera side).
    struct Correspondence {
        var source: SIMD3<Float>
        var target: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    struct Solution {
        /// World-space rigid correction to premultiply onto frame data.
        var transform: simd_float4x4
        /// Translation magnitude measured at the correspondence centroid
        /// (metres) — the honest "how far did the frame move" number, free of
        /// the rotation lever arm a world-origin translation would carry.
        var translation: Float
        /// Rotation angle (radians).
        var rotation: Float
        /// Point-to-plane RMS before/after the correction, over the pairs that
        /// survived the residual trim. `rmsAfter` should not exceed
        /// `rmsBefore`; a caller treating that as a rejection signal guards
        /// against a solve that chased outliers.
        var rmsBefore: Float
        var rmsAfter: Float
        /// Pairs that survived the trim and constrained the solve.
        var pairsUsed: Int
    }

    /// Fewer pairs than this can't constrain 6 DoF against LiDAR noise —
    /// callers should treat a nil solve as "leave the ARKit pose alone".
    /// 150 (was 300): a small targeted subject fills a fraction of the frame,
    /// and the 300 bar starved object scans to `applied 0/577` even with
    /// ROI-aware sampling; 150 point-to-plane rows still overdetermine the
    /// 6 unknowns ~25× (per-axis estimate noise ~0.5 mm at σ 3 mm).
    static let minCorrespondences = 150

    /// Solves for the small rigid transform that best aligns `source` points
    /// onto their matched model planes, damped toward identity (= the ARKit
    /// pose prior). Returns nil when there is too little to solve on.
    ///
    /// `priorStrength` is the fraction of the evidence the prior counts as:
    /// each of the N pairs contributes one unit row, the prior contributes
    /// `priorStrength × N` unit rows saying "don't move". Because the pairs
    /// are fixed while the step re-linearises, iterating damped steps
    /// converges to the *undamped* optimum in every direction the geometry
    /// constrains (each step solves the remaining residual afresh) while
    /// directions with no data signal never move off the prior — degenerate
    /// protection without under-correction.
    static func solve(_ correspondences: [Correspondence],
                      priorStrength: Float = 0.15,
                      iterations: Int = 8) -> Solution? {
        guard correspondences.count >= minCorrespondences else { return nil }
        let pairs = correspondences

        // Centre the working frame on the source centroid: rotation then acts
        // about the data instead of the world origin, which keeps the normal
        // equations well-conditioned (a scene 3 m from the origin couples the
        // rotation and translation columns badly in Float-scale sums).
        var centroid = SIMD3<Double>()
        for pair in pairs { centroid += SIMD3<Double>(pair.source) }
        centroid /= Double(pairs.count)
        var meanRadiusSq = 0.0
        for pair in pairs {
            meanRadiusSq += simd_length_squared(SIMD3<Double>(pair.source) - centroid)
        }
        meanRadiusSq /= Double(pairs.count)

        var rotationM = matrix_identity_double3x3
        var translation = SIMD3<Double>()
        var residuals = [Double](repeating: 0, count: pairs.count)
        var sortScratch = residuals

        /// Point-to-plane residuals under the current estimate, and the robust
        /// inlier cutoff: 3× the median magnitude, floored at 6 mm so a
        /// near-perfect frame doesn't trim on micrometre noise. Re-derived
        /// every iteration (trimmed ICP): moved objects and mismatched thin
        /// structure stay out, while high-leverage pairs a one-shot trim would
        /// discard for good (the far corners carrying most of the rotation
        /// signal) rejoin as soon as the first step shrinks their residuals.
        func residualsAndCutoff() -> Double {
            for (i, pair) in pairs.enumerated() {
                let s = rotationM * (SIMD3<Double>(pair.source) - centroid) + translation
                let q = SIMD3<Double>(pair.target) - centroid
                residuals[i] = simd_dot(SIMD3<Double>(pair.normal), s - q)
            }
            for i in 0..<residuals.count { sortScratch[i] = abs(residuals[i]) }
            sortScratch.sort()
            return max(0.006, 3 * sortScratch[sortScratch.count / 2])
        }

        for _ in 0..<max(iterations, 1) {
            let cutoff = residualsAndCutoff()
            var hessian = [Double](repeating: 0, count: 36)   // row-major 6×6
            var gradient = [Double](repeating: 0, count: 6)
            var inliers = 0
            for (i, pair) in pairs.enumerated() {
                let residual = residuals[i]
                guard abs(residual) <= cutoff else { continue }
                inliers += 1
                let s = rotationM * (SIMD3<Double>(pair.source) - centroid) + translation
                let n = SIMD3<Double>(pair.normal)
                let sxn = simd_cross(s, n)
                let row = [sxn.x, sxn.y, sxn.z, n.x, n.y, n.z]
                for a in 0..<6 {
                    gradient[a] -= row[a] * residual
                    for b in a..<6 { hessian[a * 6 + b] += row[a] * row[b] }
                }
            }
            guard inliers >= minCorrespondences else { return nil }
            // Prior damping, matched to the blocks' natural scale: translation
            // rows sum |n|² = 1 each, rotation rows sum |p×n|² ~ r̄² each.
            let lambdaT = Double(priorStrength) * Double(inliers)
            let lambdaR = lambdaT * max(meanRadiusSq, 1e-4)
            for a in 0..<6 {
                for b in 0..<a { hessian[a * 6 + b] = hessian[b * 6 + a] }
            }
            for a in 0..<3 { hessian[a * 6 + a] += lambdaR }
            for a in 3..<6 { hessian[a * 6 + a] += lambdaT }
            guard let step = solve6(hessian, gradient) else { break }
            let omega = SIMD3<Double>(step[0], step[1], step[2])
            let delta = SIMD3<Double>(step[3], step[4], step[5])
            let deltaR = rotationMatrix(axisAngle: omega)
            rotationM = deltaR * rotationM
            translation = deltaR * translation + delta
            if simd_length(omega) < 1e-7, simd_length(delta) < 1e-7 { break }
        }

        // Improvement report over the pairs the final estimate trusts: their
        // RMS at the ARKit pose vs. after the correction. Judging on the final
        // inlier set keeps a moved object's gross residuals from swamping the
        // millimetre improvement the acceptance guard actually cares about.
        let finalCutoff = residualsAndCutoff()
        var beforeSq = 0.0, afterSq = 0.0
        var inliersUsed = 0
        for (i, pair) in pairs.enumerated() {
            guard abs(residuals[i]) <= finalCutoff else { continue }
            inliersUsed += 1
            afterSq += residuals[i] * residuals[i]
            let atIdentity = Double(simd_dot(pair.normal, pair.source - pair.target))
            beforeSq += atIdentity * atIdentity
        }
        guard inliersUsed >= minCorrespondences else { return nil }
        let rmsBefore = (beforeSq / Double(inliersUsed)).squareRoot()
        let rmsAfter = (afterSq / Double(inliersUsed)).squareRoot()

        // Local (about-centroid) → world: T = Trans(c) · T_local · Trans(−c).
        let worldT = translation + centroid - rotationM * centroid
        let rf = simd_float3x3(SIMD3<Float>(rotationM.columns.0),
                               SIMD3<Float>(rotationM.columns.1),
                               SIMD3<Float>(rotationM.columns.2))
        let transform = simd_float4x4(SIMD4<Float>(rf.columns.0, 0),
                                      SIMD4<Float>(rf.columns.1, 0),
                                      SIMD4<Float>(rf.columns.2, 0),
                                      SIMD4<Float>(SIMD3<Float>(worldT), 1))
        let trace = rotationM.columns.0.x + rotationM.columns.1.y + rotationM.columns.2.z
        let angle = acos(min(max((trace - 1) * 0.5, -1), 1))
        return Solution(transform: transform,
                        translation: Float(simd_length(translation)),
                        rotation: Float(angle),
                        rmsBefore: Float(rmsBefore),
                        rmsAfter: Float(rmsAfter),
                        pairsUsed: inliersUsed)
    }

    /// Best-fit plane normal of a small model neighbourhood (the covariance's
    /// smallest eigenvector), oriented into `fallback`'s hemisphere. Returns
    /// `fallback` (expected unit length — the fused view ray, camera side)
    /// when the neighbourhood is too sparse, too curved or too thick to trust
    /// a plane through it: point-to-plane with a made-up normal is worse than
    /// point-to-ray with an honest one.
    static func planeNormal(_ points: [SIMD3<Float>],
                            fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard points.count >= 4 else { return fallback }
        var mean = SIMD3<Double>()
        for p in points { mean += SIMD3<Double>(p) }
        mean /= Double(points.count)
        var xx = 0.0, xy = 0.0, xz = 0.0, yy = 0.0, yz = 0.0, zz = 0.0
        for p in points {
            let d = SIMD3<Double>(p) - mean
            xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
            yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
        }
        let inv = 1 / Double(points.count)
        xx *= inv; xy *= inv; xz *= inv; yy *= inv; yz *= inv; zz *= inv
        let trace = xx + yy + zz
        guard trace > 1e-12 else { return fallback }
        // Smallest eigenvector of covariance C = largest of (trace·I − C);
        // both are PSD, so plain power iteration converges — and seeding with
        // the expected normal keeps it off the wrong eigenvector's axis.
        let flipped = simd_double3x3(SIMD3<Double>(trace - xx, -xy, -xz),
                                     SIMD3<Double>(-xy, trace - yy, -yz),
                                     SIMD3<Double>(-xz, -yz, trace - zz))
        var v = SIMD3<Double>(fallback)
        if simd_length_squared(v) < 1e-12 { v = SIMD3<Double>(0, 1, 0) }
        for _ in 0..<24 {
            let w = flipped * v
            let length = simd_length(w)
            guard length > 1e-20 else { return fallback }
            v = w / length
        }
        let covariance = simd_double3x3(SIMD3<Double>(xx, xy, xz),
                                        SIMD3<Double>(xy, yy, yz),
                                        SIMD3<Double>(xz, yz, zz))
        let thicknessVar = simd_dot(v, covariance * v)
        let inPlaneVar = (trace - thicknessVar) / 2
        // Trust gates: the patch must be clearly flatter than it is wide, and
        // its absolute thickness must be surface-noise scale (≤ ~12 mm RMS) —
        // a curved object at this radius or a crinkled early-scan wall keeps
        // the honest fallback instead of a misleading plane.
        guard thicknessVar < inPlaneVar * 0.5, thicknessVar.squareRoot() < 0.012 else {
            return fallback
        }
        var normal = SIMD3<Float>(v)
        if simd_dot(normal, fallback) < 0 { normal = -normal }
        return simd_normalize(normal)
    }

    // MARK: - Internals

    /// Gaussian elimination with partial pivoting for the (damped, symmetric
    /// positive-definite) 6×6 normal equations. Row-major `matrix`.
    private static func solve6(_ matrix: [Double], _ rhs: [Double]) -> [Double]? {
        var a = matrix
        var b = rhs
        for column in 0..<6 {
            var pivot = column
            for row in (column + 1)..<6 where abs(a[row * 6 + column]) > abs(a[pivot * 6 + column]) {
                pivot = row
            }
            guard abs(a[pivot * 6 + column]) > 1e-12 else { return nil }
            if pivot != column {
                for c in 0..<6 { a.swapAt(pivot * 6 + c, column * 6 + c) }
                b.swapAt(pivot, column)
            }
            let invPivot = 1 / a[column * 6 + column]
            for row in (column + 1)..<6 {
                let factor = a[row * 6 + column] * invPivot
                if factor == 0 { continue }
                for c in column..<6 { a[row * 6 + c] -= factor * a[column * 6 + c] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: 6)
        for row in stride(from: 5, through: 0, by: -1) {
            var sum = b[row]
            for c in (row + 1)..<6 { sum -= a[row * 6 + c] * x[c] }
            x[row] = sum / a[row * 6 + row]
        }
        return x
    }

    /// Rodrigues rotation from an axis-angle vector.
    private static func rotationMatrix(axisAngle omega: SIMD3<Double>) -> simd_double3x3 {
        let theta = simd_length(omega)
        guard theta > 1e-12 else { return matrix_identity_double3x3 }
        let axis = omega / theta
        let c = cos(theta), s = sin(theta), t = 1 - c
        let x = axis.x, y = axis.y, z = axis.z
        return simd_double3x3(
            SIMD3<Double>(t * x * x + c, t * x * y + s * z, t * x * z - s * y),
            SIMD3<Double>(t * x * y - s * z, t * y * y + c, t * y * z + s * x),
            SIMD3<Double>(t * x * z + s * y, t * y * z - s * x, t * z * z + c))
    }
}
