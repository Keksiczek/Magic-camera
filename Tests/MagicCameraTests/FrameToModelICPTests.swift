//
//  FrameToModelICPTests.swift
//  MagicCameraTests
//
//  Verifies the damped point-to-plane solver behind per-frame frame-to-model
//  registration: a synthetic model with a frame offset by a known transform
//  must be recovered (translation / rotation / mixed / noisy / outliers), and
//  the degenerate single-plane case must keep the ARKit prior for the
//  directions the geometry can't constrain.
//
import XCTest
import simd
@testable import MagicCamera

final class FrameToModelICPTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTransform(rotation: simd_float3x3,
                               translation: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4<Float>(rotation.columns.0, 0),
                      SIMD4<Float>(rotation.columns.1, 0),
                      SIMD4<Float>(rotation.columns.2, 0),
                      SIMD4<Float>(translation, 1))
    }

    private func rotation(axis: SIMD3<Float>, angle: Float) -> simd_float3x3 {
        simd_float3x3(simd_quatf(angle: angle, axis: simd_normalize(axis)))
    }

    private func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = m * SIMD4<Float>(p, 1)
        return SIMD3(r.x, r.y, r.z)
    }

    /// Three orthogonal planes (floor + two walls) around a corner, placed
    /// away from the world origin like a real room scan.
    private func cornerScene() -> (points: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        let origin = SIMD3<Float>(2.0, 0.8, -1.5)
        var u: Float = 0
        while u <= 1.2 {
            var v: Float = 0
            while v <= 1.2 {
                points.append(origin + SIMD3(u, 0, v)); normals.append(SIMD3(0, 1, 0))
                points.append(origin + SIMD3(u, v, 0)); normals.append(SIMD3(0, 0, 1))
                points.append(origin + SIMD3(0, u, v)); normals.append(SIMD3(1, 0, 0))
                v += 0.04
            }
            u += 0.04
        }
        return (points, normals)
    }

    /// Correspondences for a frame that is the model transformed by `offset`.
    private func pairs(offset: simd_float4x4, noise: Float = 0,
                       outliers: Int = 0) -> [FrameToModelICP.Correspondence] {
        let scene = cornerScene()
        var rng: UInt64 = 7
        func rand() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: rng >> 11)) / Float(Int64.max)
        }
        var result: [FrameToModelICP.Correspondence] = []
        for i in 0..<scene.points.count {
            var source = apply(offset, scene.points[i])
            if noise > 0 { source += SIMD3(rand(), rand(), rand()) * noise }
            result.append(.init(source: source, target: scene.points[i],
                                normal: scene.normals[i]))
        }
        for i in 0..<outliers {   // a coherently displaced "moved object"
            let p = scene.points[i % scene.points.count]
            result.append(.init(source: apply(offset, p) + SIMD3(0.1, 0.05, -0.08),
                                target: p, normal: scene.normals[i % scene.points.count]))
        }
        return result
    }

    /// Worst displacement the (should-be-identity) composed transform causes
    /// across the scene — the honest recovery metric; judging the translation
    /// column at the world origin would let a leftover micro-rotation about
    /// the distant scene read as fake millimetres.
    private func residualAtData(_ m: simd_float4x4) -> Float {
        let points = cornerScene().points
        var worst: Float = 0
        var i = 0
        while i < points.count {
            worst = max(worst, simd_distance(apply(m, points[i]), points[i]))
            i += 17
        }
        return worst
    }

    // MARK: - Recovery

    func testRecoversPureTranslation() throws {
        let truth = makeTransform(rotation: matrix_identity_float3x3,
                                  translation: SIMD3(0.008, -0.005, 0.003))
        let solution = try XCTUnwrap(FrameToModelICP.solve(pairs(offset: truth)))
        XCTAssertLessThan(residualAtData(solution.transform * truth), 0.0005)
        XCTAssertLessThan(solution.rotation, 0.001)
        XCTAssertEqual(solution.translation, 0.0099, accuracy: 0.0008)
        XCTAssertLessThan(solution.rmsAfter, solution.rmsBefore)
    }

    func testRecoversPureRotation() throws {
        let scene = cornerScene().points
        var centroid = SIMD3<Float>()
        for p in scene { centroid += p }
        centroid /= Float(scene.count)
        let r = rotation(axis: SIMD3(0.3, 1, 0.2), angle: 0.8 * .pi / 180)
        let truth = makeTransform(rotation: r, translation: centroid - r * centroid)
        let solution = try XCTUnwrap(FrameToModelICP.solve(pairs(offset: truth)))
        XCTAssertLessThan(residualAtData(solution.transform * truth), 0.0005)
        XCTAssertEqual(solution.rotation, 0.8 * .pi / 180, accuracy: 0.0006)
        XCTAssertLessThan(solution.translation, 0.002)
    }

    func testRecoversMixedTransform() throws {
        let r = rotation(axis: SIMD3(-0.2, 0.9, 0.4), angle: 0.5 * .pi / 180)
        let truth = makeTransform(rotation: r, translation: SIMD3(-0.006, 0.004, 0.007))
        let solution = try XCTUnwrap(FrameToModelICP.solve(pairs(offset: truth)))
        XCTAssertLessThan(residualAtData(solution.transform * truth), 0.0005)
    }

    func testRecoversUnderNoise() throws {
        let r = rotation(axis: SIMD3(0.1, 1, -0.3), angle: 0.4 * .pi / 180)
        let truth = makeTransform(rotation: r, translation: SIMD3(0.007, -0.004, 0.005))
        let solution = try XCTUnwrap(FrameToModelICP.solve(pairs(offset: truth, noise: 0.003)))
        XCTAssertLessThan(residualAtData(solution.transform * truth), 0.0015)
    }

    func testTrimsMovedObjectOutliers() throws {
        let truth = makeTransform(rotation: matrix_identity_float3x3,
                                  translation: SIMD3(0.006, 0.003, -0.005))
        let clean = pairs(offset: truth)
        let solution = try XCTUnwrap(
            FrameToModelICP.solve(pairs(offset: truth, outliers: clean.count / 10)))
        XCTAssertLessThan(residualAtData(solution.transform * truth), 0.001)
    }

    // MARK: - Degeneracy and rejection signals

    func testSinglePlaneKeepsPriorInPlane() throws {
        // Only a floor: the plane-normal (y) component is observable; in-plane
        // translation and yaw are not, and must stay at the ARKit answer.
        var floor: [FrameToModelICP.Correspondence] = []
        let offset = makeTransform(rotation: rotation(axis: SIMD3(0, 1, 0),
                                                      angle: 0.4 * .pi / 180),
                                   translation: SIMD3(0.005, 0.008, -0.004))
        var u: Float = 0
        while u <= 1.2 {
            var v: Float = 0
            while v <= 1.2 {
                let p = SIMD3<Float>(2.0 + u, 0.8, -1.5 + v)
                floor.append(.init(source: apply(offset, p), target: p,
                                   normal: SIMD3(0, 1, 0)))
                v += 0.03
            }
            u += 0.03
        }
        let solution = try XCTUnwrap(FrameToModelICP.solve(floor))
        let probe = apply(offset, SIMD3<Float>(2.5, 0.8, -1.0))
        let corrected = apply(solution.transform, probe)
        XCTAssertEqual(corrected.y, 0.8, accuracy: 0.0005)          // normal recovered
        XCTAssertEqual(corrected.x, probe.x, accuracy: 0.001)       // prior holds x
        XCTAssertEqual(corrected.z, probe.z, accuracy: 0.001)       // prior holds z
        XCTAssertEqual(solution.translation, 0.008, accuracy: 0.001)
        XCTAssertLessThan(solution.rotation, 0.002)
    }

    func testTooFewCorrespondencesReturnsNil() {
        let truth = makeTransform(rotation: matrix_identity_float3x3,
                                  translation: SIMD3(0.005, 0, 0))
        let few = Array(pairs(offset: truth).prefix(FrameToModelICP.minCorrespondences - 1))
        XCTAssertNil(FrameToModelICP.solve(few))
    }

    func testBigDiagonalOffsetReportsAboveRejectionBar() throws {
        // Diagonal so every plane family sees it; the recorder rejects
        // anything past 2 cm / 1° as relocalisation-scale.
        let truth = makeTransform(rotation: matrix_identity_float3x3,
                                  translation: SIMD3(0.03, 0.025, -0.028))
        let solution = try XCTUnwrap(FrameToModelICP.solve(pairs(offset: truth)))
        XCTAssertGreaterThan(solution.translation, 0.02)
    }

    // MARK: - Plane-fit normals

    func testPlaneNormalOnFlatPatch() {
        var patch: [SIMD3<Float>] = []
        for i in 0..<5 {
            for j in 0..<5 {
                patch.append(SIMD3(Float(i) * 0.02,
                                   0.001 * Float((i + j) % 2),
                                   Float(j) * 0.02))
            }
        }
        let normal = FrameToModelICP.planeNormal(patch, fallback: SIMD3(0.1, 0.9, 0.1))
        XCTAssertGreaterThan(normal.y, 0.99)
        // Orientation follows the fallback's hemisphere (camera side).
        let flipped = FrameToModelICP.planeNormal(patch, fallback: SIMD3(0, -1, 0))
        XCTAssertLessThan(flipped.y, -0.99)
    }

    // MARK: - Correction magnitude

    /// The runaway guard used to size the cumulative correction by its
    /// translation column, which is taken about the world origin. Replays the
    /// 2026-07-20 device room: 131 m² whose cloud centroid sat 7.67 m from the
    /// session origin, corrected by 2.3° of ordinary yaw drift. That reads as
    /// 302 mm about the origin — the exact figure that froze the correction
    /// 27 s into a 4.5-minute scan — while the room itself barely moved.
    func testDragIsMeasuredAtTheDataNotTheWorldOrigin() {
        let centroid = SIMD3<Float>(-7.61, -0.31, -0.95)   // device cloud centroid
        let angle: Float = 2.26 * .pi / 180
        let c = cos(angle), s = sin(angle)
        let yaw = simd_float3x3(SIMD3(c, 0, -s), SIMD3(0, 1, 0), SIMD3(s, 0, c))
        // Rotation about the scene, expressed in world terms the way the
        // solver composes it: T = Trans(c) · R · Trans(−c).
        let correction = makeTransform(rotation: yaw, translation: centroid - yaw * centroid)

        let originColumn = simd_length(SIMD3<Float>(correction.columns.3.x,
                                                    correction.columns.3.y,
                                                    correction.columns.3.z))
        XCTAssertEqual(originColumn, 0.302, accuracy: 0.005)
        XCTAssertGreaterThan(originColumn, 0.30, "the bound the device tripped")

        // Measured where the data is, the same correction is jitter-scale at
        // the centroid and a few centimetres at the far wall — under the bound,
        // as 2.3° of drift correction on a room should be.
        XCTAssertLessThan(FrameToModelICP.drag(of: correction, at: centroid), 0.001)
        let farWall = centroid + SIMD3<Float>(2.5, 0, 0)
        XCTAssertEqual(FrameToModelICP.drag(of: correction, at: farWall), 0.099, accuracy: 0.005)
        XCTAssertLessThan(FrameToModelICP.drag(of: correction, at: farWall), 0.30)
    }

    /// A correction that genuinely translates the model is reported at full
    /// magnitude wherever it is measured — the guard still catches self-drift.
    func testDragReportsGenuineTranslationEverywhere() {
        let slide = makeTransform(rotation: matrix_identity_float3x3,
                                  translation: SIMD3(0.35, 0, 0))
        XCTAssertEqual(FrameToModelICP.drag(of: slide, at: SIMD3(0, 0, 0)), 0.35, accuracy: 1e-5)
        XCTAssertEqual(FrameToModelICP.drag(of: slide, at: SIMD3(-7.61, -0.31, -0.95)),
                       0.35, accuracy: 1e-5)
    }

    // MARK: - Levelling

    func testTiltSeesRollAndPitchButNotYaw() {
        let yaw = makeTransform(rotation: rotation(axis: SIMD3(0, 1, 0), angle: 0.5),
                                translation: SIMD3(0.2, 0, -0.4))
        XCTAssertEqual(FrameToModelICP.tilt(of: yaw), 0, accuracy: 1e-5,
                       "spinning about gravity does not tip anything")
        for axis in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 1)] {
            let tipped = makeTransform(rotation: rotation(axis: axis, angle: 0.04),
                                       translation: .zero)
            XCTAssertEqual(FrameToModelICP.tilt(of: tipped), 0.04, accuracy: 1e-4)
        }
    }

    func testLevellingRemovesTheTiltAndKeepsTheYaw() {
        let tip = rotation(axis: SIMD3(1, 0, 0.3), angle: 0.05)
        let spin = rotation(axis: SIMD3(0, 1, 0), angle: 0.12)
        let m = makeTransform(rotation: tip * spin, translation: SIMD3(0.03, -0.01, 0.02))
        let leveled = FrameToModelICP.leveled(m, about: .zero)

        XCTAssertEqual(FrameToModelICP.tilt(of: leveled), 0, accuracy: 1e-5)
        // Yaw survives: the horizontal heading is unchanged.
        let heading = { (t: simd_float4x4) -> Float in
            atan2(t.columns.0.z, t.columns.0.x)
        }
        XCTAssertEqual(heading(leveled), heading(m), accuracy: 1e-3)
        // Still a rigid transform.
        let r = simd_float3x3(SIMD3(leveled.columns.0.x, leveled.columns.0.y, leveled.columns.0.z),
                              SIMD3(leveled.columns.1.x, leveled.columns.1.y, leveled.columns.1.z),
                              SIMD3(leveled.columns.2.x, leveled.columns.2.y, leveled.columns.2.z))
        XCTAssertEqual(simd_determinant(r), 1, accuracy: 1e-4)
    }

    func testLevellingLeavesTheDataWhereItWas() {
        // Re-anchoring is the whole point: levelling about the world origin would
        // shove the model by the lever arm, which is worse than the tilt.
        let pivot = SIMD3<Float>(-1.34, -0.41, -2.04)     // device cloud centroid
        let m = makeTransform(rotation: rotation(axis: SIMD3(0.3, 1, 0), angle: 0.03),
                              translation: SIMD3(0.01, 0.002, -0.008))
        let leveled = FrameToModelICP.leveled(m, about: pivot)
        XCTAssertEqual(FrameToModelICP.drag(of: leveled, at: pivot),
                       FrameToModelICP.drag(of: m, at: pivot), accuracy: 1e-4,
                       "the pivot lands where the unlevelled correction put it")
    }

    func testLevellingAnAlreadyLevelCorrectionChangesNothing() {
        let m = makeTransform(rotation: rotation(axis: SIMD3(0, 1, 0), angle: 0.08),
                              translation: SIMD3(0.02, 0.05, -0.03))
        let leveled = FrameToModelICP.leveled(m, about: SIMD3(1, 2, 3))
        for p in [SIMD3<Float>(0, 0, 0), SIMD3(3, -1, 2), SIMD3(-5, 0.4, 7)] {
            let a = m * SIMD4<Float>(p, 1), b = leveled * SIMD4<Float>(p, 1)
            XCTAssertEqual(simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)),
                           0, accuracy: 1e-4)
        }
    }

    func testLevellingStopsTiltCompounding() {
        // The failure mode itself: a small pitch bias, applied every frame,
        // registers against a model the previous frames already tipped. 200
        // frames of 0.02° compound into a warped floor; levelled, they cannot.
        let bias = makeTransform(rotation: rotation(axis: SIMD3(1, 0, 0), angle: 0.00035),
                                 translation: .zero)
        var raw = matrix_identity_float4x4
        var leveled = matrix_identity_float4x4
        for _ in 0..<200 {
            raw = bias * raw
            leveled = FrameToModelICP.leveled(bias * leveled, about: .zero)
        }
        XCTAssertEqual(FrameToModelICP.tilt(of: raw) * 180 / .pi, 4.0, accuracy: 0.1,
                       "unchecked, the bias integrates into degrees of tilt")
        XCTAssertEqual(FrameToModelICP.tilt(of: leveled), 0, accuracy: 1e-4)
    }

    func testPlaneNormalFallsBackWhenUntrustworthy() {
        // Too sparse.
        let sparse = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.01, 0, 0), SIMD3<Float>(0, 0, 0.01)]
        XCTAssertEqual(FrameToModelICP.planeNormal(sparse, fallback: SIMD3(0, 0, 1)),
                       SIMD3<Float>(0, 0, 1))
        // Clearly curved (a 4 cm sphere cap) — a plane through it would lie.
        var curved: [SIMD3<Float>] = []
        for i in -3...3 {
            for j in -3...3 {
                let x = Float(i) * 0.012, z = Float(j) * 0.012
                curved.append(SIMD3(x, sqrt(max(0.0016 - x * x - z * z, 0)), z))
            }
        }
        XCTAssertEqual(FrameToModelICP.planeNormal(curved, fallback: SIMD3(0, 1, 0)),
                       SIMD3<Float>(0, 1, 0))
    }
}
