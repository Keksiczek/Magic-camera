import XCTest
import simd
@testable import MagicCamera

/// The graded per-sample confidence model. The invariant that keeps this safe on
/// device is tested first: **no single signal may reject a sample** — only the
/// product of several independent doubts can.
final class DepthSampleConfidenceTests: XCTestCase {

    // MARK: - The safety invariant

    func testNoSingleSignalCanRejectASample() {
        let worstEdge = DepthSampleConfidence.edgeFactor(relativeJump: 1)
        let worstIncidence = DepthSampleConfidence.incidenceFactor(cosIncidence: 0)
        let worstRange = DepthSampleConfidence.rangeFactor(depth: 7, maxDepth: 7)
        let worstRadial = DepthSampleConfidence.radialFactor(normalizedRadius: 1)
        let worstMotion = DepthSampleConfidence.motionFactor(angularSpeed: 99, linearSpeed: 99)
        for factor in [worstEdge, worstIncidence, worstRange, worstRadial, worstMotion] {
            XCTAssertFalse(DepthSampleConfidence.isRejected(grade: factor),
                           "a single signal at its floor must not reject on its own")
        }
    }

    /// The invariant has to hold through `grade(…)` itself, not just across the
    /// five factor functions. `frameGrade` is the one term that arrives
    /// pre-computed from the caller, and it used to be clamped `max(·, 0)` — so a
    /// caller passing 0 collapsed the product regardless of the other four, which
    /// is a single signal rejecting alone. Both entry points are pinned because
    /// the GPU reads its copy from `gpuGrading`.
    func testAZeroFrameGradeCannotRejectAPerfectSample() {
        let grade = DepthSampleConfidence.grade(
            relativeJump: 0, cosIncidence: 1, depth: 0.5, maxDepth: 7,
            normalizedRadius: 0, frameGrade: 0)
        XCTAssertFalse(DepthSampleConfidence.isRejected(grade: grade),
                       "frameGrade alone must not reject an otherwise perfect sample")
        XCTAssertGreaterThanOrEqual(
            DepthSampleConfidence.gpuGrading(enabled: true, frameGrade: 0).frameGrade,
            DepthSampleConfidence.motionFloor,
            "the kernel must receive the floored value, not a raw 0")
    }

    func testAgreeingSignalsDoReject() {
        // Bleed's signature: a depth cliff, seen edge-on. Two independent doubts.
        let grade = DepthSampleConfidence.grade(
            relativeJump: 0.95, cosIncidence: 0.02, depth: 1.0, maxDepth: 5,
            normalizedRadius: 0, frameGrade: 1)
        XCTAssertTrue(DepthSampleConfidence.isRejected(grade: grade))
    }

    func testCleanCloseCentredSampleIsUngraded() {
        let grade = DepthSampleConfidence.grade(
            relativeJump: 0, cosIncidence: 1, depth: 1.0, maxDepth: 5,
            normalizedRadius: 0, frameGrade: 1)
        XCTAssertEqual(grade, 1, accuracy: 1e-6)
    }

    /// A real wall seen at a grazing angle is honest, just awkward — it must
    /// survive so a later, better view can redeem it.
    func testGrazingButOtherwiseCleanSampleSurvives() {
        let grade = DepthSampleConfidence.grade(
            relativeJump: 0, cosIncidence: 0.05, depth: 1.2, maxDepth: 7,
            normalizedRadius: 0.2, frameGrade: 1)
        XCTAssertFalse(DepthSampleConfidence.isRejected(grade: grade))
        XCTAssertEqual(grade, DepthSampleConfidence.incidenceFloor, accuracy: 1e-5)
    }

    // MARK: - Individual factors

    func testEdgeFactorIsFlatBelowTheKneeThenRamps() {
        XCTAssertEqual(DepthSampleConfidence.edgeFactor(relativeJump: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(DepthSampleConfidence.edgeFactor(
            relativeJump: DepthSampleConfidence.edgeKnee), 1, accuracy: 1e-6)
        XCTAssertEqual(DepthSampleConfidence.edgeFactor(relativeJump: 1),
                       DepthSampleConfidence.edgeFloor, accuracy: 1e-5)
        // Monotonically decreasing between.
        let mid = DepthSampleConfidence.edgeFactor(relativeJump: 0.7)
        XCTAssertLessThan(mid, 1)
        XCTAssertGreaterThan(mid, DepthSampleConfidence.edgeFloor)
    }

    func testIncidenceFactorIsOneAboveTheTrustedAngle() {
        XCTAssertEqual(DepthSampleConfidence.incidenceFactor(cosIncidence: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(DepthSampleConfidence.incidenceFactor(
            cosIncidence: DepthSampleConfidence.trustedCos), 1, accuracy: 1e-6)
        XCTAssertEqual(DepthSampleConfidence.incidenceFactor(
            cosIncidence: DepthSampleConfidence.grazingCos),
                       DepthSampleConfidence.incidenceFloor, accuracy: 1e-5)
    }

    func testRangeFactorOnlyBitesBeyondTheTrustedRange() {
        XCTAssertEqual(DepthSampleConfidence.rangeFactor(depth: 1.0, maxDepth: 7), 1, accuracy: 1e-6)
        XCTAssertEqual(DepthSampleConfidence.rangeFactor(
            depth: DepthSampleConfidence.trustedRange, maxDepth: 7), 1, accuracy: 1e-6)
        XCTAssertEqual(DepthSampleConfidence.rangeFactor(depth: 7, maxDepth: 7),
                       DepthSampleConfidence.rangeFloor, accuracy: 1e-5)
        // An object-mode range (2.5 m cap) never drops far: the whole capture
        // sits close, so the factor must stay mild there.
        XCTAssertGreaterThan(DepthSampleConfidence.rangeFactor(depth: 2.0, maxDepth: 2.5), 0.75)
    }

    func testRadialFactorIsMildAndOnlyAtTheEdgeOfFrame() {
        XCTAssertEqual(DepthSampleConfidence.radialFactor(normalizedRadius: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(DepthSampleConfidence.radialFactor(normalizedRadius: 1),
                       DepthSampleConfidence.radialFloor, accuracy: 1e-5)
        XCTAssertGreaterThanOrEqual(DepthSampleConfidence.radialFloor, 0.8)
    }

    func testMotionFactorTakesTheWorstAxis() {
        let steady = DepthSampleConfidence.motionFactor(angularSpeed: 0.1, linearSpeed: 0.05)
        XCTAssertEqual(steady, 1, accuracy: 1e-6)
        // Fast rotation alone is enough to grade the frame down.
        let spun = DepthSampleConfidence.motionFactor(angularSpeed: 2.0, linearSpeed: 0.01)
        XCTAssertEqual(spun, DepthSampleConfidence.motionFloor, accuracy: 1e-5)
        let lunged = DepthSampleConfidence.motionFactor(angularSpeed: 0.01, linearSpeed: 2.0)
        XCTAssertEqual(lunged, DepthSampleConfidence.motionFloor, accuracy: 1e-5)
    }

    // MARK: - Incidence from a depth map

    /// A plane facing the camera: the estimated normal is the view ray, cos ≈ 1.
    func testCosIncidenceIsOneOnAFrontFacingPlane() {
        let cos = DepthSampleConfidence.cosIncidence(
            depth: 2, u: 64, v: 48, left: 2, right: 2, up: 2, down: 2,
            fx: 200, fy: 200, cx: 64.5, cy: 48.5)
        XCTAssertEqual(cos, 1, accuracy: 1e-3)
    }

    /// A depth cliff — the bleed case. The local "surface" spans the gap, so its
    /// normal is nearly perpendicular to the ray.
    func testCosIncidenceCollapsesOnADepthCliff() {
        let cos = DepthSampleConfidence.cosIncidence(
            depth: 1.0, u: 64, v: 48, left: 1.0, right: 3.0, up: 1.0, down: 1.0,
            fx: 200, fy: 200, cx: 64.5, cy: 48.5)
        XCTAssertLessThan(cos, DepthSampleConfidence.trustedCos)
        XCTAssertLessThan(DepthSampleConfidence.incidenceFactor(cosIncidence: cos), 1)
    }

    /// Missing neighbours must not be read as a bad measurement.
    func testCosIncidenceIsUngradedWhenAnAxisHasNoNeighbour() {
        let cos = DepthSampleConfidence.cosIncidence(
            depth: 2, u: 64, v: 48, left: 0, right: 0, up: 2, down: 2,
            fx: 200, fy: 200, cx: 64.5, cy: 48.5)
        XCTAssertEqual(cos, 1, accuracy: 1e-6)
    }

    /// A slanted-but-real plane: steep enough to be graded, nowhere near rejected.
    func testSlantedPlaneIsGradedNotRejected() {
        // Depth ramps 10 cm per texel across x — a strongly tilted surface.
        let cos = DepthSampleConfidence.cosIncidence(
            depth: 2.0, u: 64, v: 48, left: 1.9, right: 2.1, up: 2.0, down: 2.0,
            fx: 200, fy: 200, cx: 64.5, cy: 48.5)
        let grade = DepthSampleConfidence.grade(
            relativeJump: 0, cosIncidence: cos, depth: 2.0, maxDepth: 5,
            normalizedRadius: 0.1, frameGrade: 1)
        XCTAssertFalse(DepthSampleConfidence.isRejected(grade: grade))
    }

    // MARK: - Relative jump

    func testRelativeJumpIsZeroOnAFlatPatch() {
        let jump = DepthSampleConfidence.relativeJump(
            depth: 2, threshold: 0.12, ring1: [2, 2, 2, 2], ring2: [2, 2, 2, 2], ring3: [2, 2, 2, 2])
        XCTAssertEqual(jump, 0, accuracy: 1e-6)
    }

    func testRelativeJumpReachesOneAtTheRejectBar() {
        // ring-1 jump exactly at threshold × depth (0.12 × 2 = 0.24).
        let jump = DepthSampleConfidence.relativeJump(
            depth: 2, threshold: 0.12, ring1: [2.24, 2, 2, 2],
            ring2: [2, 2, 2, 2], ring3: [2, 2, 2, 2])
        XCTAssertEqual(jump, 1, accuracy: 1e-4)
    }

    func testRelativeJumpAllowsWiderJumpsOnOuterRings() {
        // The same absolute jump on ring 3 is only a third as suspicious.
        let jump = DepthSampleConfidence.relativeJump(
            depth: 2, threshold: 0.12, ring1: [2, 2, 2, 2],
            ring2: [2, 2, 2, 2], ring3: [2.24, 2, 2, 2])
        XCTAssertEqual(jump, 1.0 / 3.0, accuracy: 1e-4)
    }

    func testRelativeJumpIsZeroWhenTheThresholdIsDisabled() {
        XCTAssertEqual(DepthSampleConfidence.relativeJump(
            depth: 2, threshold: 0, ring1: [9, 9, 9, 9], ring2: [], ring3: []), 0, accuracy: 1e-6)
    }

    /// A neighbour of 0 means "no depth returned there", and `unprojectKernel`
    /// counts that as a full-size jump rather than skipping it — a texel next to a
    /// depth hole is read as a silhouette. This pins the CPU path to that, because
    /// the kernel is what runs on device: the previous "skip invalid neighbours"
    /// contract was a second opinion that only survived because nothing in
    /// production called this function.
    func testRelativeJumpTreatsAMissingNeighbourAsAJumpLikeTheKernel() {
        let jump = DepthSampleConfidence.relativeJump(
            depth: 2, threshold: 0.12, ring1: [0, 2, 2, 2], ring2: [], ring3: [])
        XCTAssertGreaterThan(jump, 1, "a hole beside the texel must reject, as the GPU does")
    }

    // MARK: - GPU hand-off

    func testGpuGradingCarriesTheSwiftConstants() {
        let grading = DepthSampleConfidence.gpuGrading(enabled: true, frameGrade: 0.7)
        XCTAssertEqual(grading.enabled, 1)
        XCTAssertEqual(grading.edgeKnee, DepthSampleConfidence.edgeKnee)
        XCTAssertEqual(grading.edgeFloor, DepthSampleConfidence.edgeFloor)
        XCTAssertEqual(grading.grazingCos, DepthSampleConfidence.grazingCos)
        XCTAssertEqual(grading.trustedCos, DepthSampleConfidence.trustedCos)
        XCTAssertEqual(grading.incidenceFloor, DepthSampleConfidence.incidenceFloor)
        XCTAssertEqual(grading.trustedRange, DepthSampleConfidence.trustedRange)
        XCTAssertEqual(grading.rangeFloor, DepthSampleConfidence.rangeFloor)
        XCTAssertEqual(grading.trustedRadius, DepthSampleConfidence.trustedRadius)
        XCTAssertEqual(grading.radialFloor, DepthSampleConfidence.radialFloor)
        XCTAssertEqual(grading.minGrade, DepthSampleConfidence.minGrade)
        XCTAssertEqual(grading.frameGrade, 0.7, accuracy: 1e-6)
    }

    /// The lower clamp is `motionFloor`, not 0 — an out-of-range `frameGrade` must
    /// still not be able to reject a sample by itself (see
    /// `testAZeroFrameGradeCannotRejectAPerfectSample`).
    func testGpuGradingClampsTheFrameGrade() {
        XCTAssertEqual(DepthSampleConfidence.gpuGrading(enabled: false, frameGrade: 2).frameGrade, 1)
        XCTAssertEqual(DepthSampleConfidence.gpuGrading(enabled: false, frameGrade: -1).frameGrade,
                       DepthSampleConfidence.motionFloor)
        XCTAssertEqual(DepthSampleConfidence.gpuGrading(enabled: false, frameGrade: 1).enabled, 0)
    }

    // MARK: - Capture telemetry

    func testGradingStatsSummarisesEarnedConfidence() {
        var cloud = PointCloud()
        for value in [Float(1.0), 0.9, 0.8, 0.1] {
            cloud.append(position: .zero, color: .zero, confidence: value)
        }
        let stats = SpatialScanViewModel.gradingStats(cloud)
        XCTAssertEqual(stats.mean, 0.7, accuracy: 1e-5)
        XCTAssertEqual(stats.doubtfulPercent, 25, accuracy: 1e-3)
        XCTAssertEqual(stats.minimum, 0.1, accuracy: 1e-5)
    }

    func testGradingStatsIgnoresTombstones() {
        var cloud = PointCloud()
        cloud.append(position: .zero, color: .zero, confidence: 1)
        cloud.append(position: .zero, color: .zero, confidence: -1)
        let stats = SpatialScanViewModel.gradingStats(cloud)
        XCTAssertEqual(stats.mean, 1, accuracy: 1e-5)
        XCTAssertEqual(stats.doubtfulPercent, 0, accuracy: 1e-5)
    }

    func testGradingStatsHandlesAnEmptyCloud() {
        let stats = SpatialScanViewModel.gradingStats(PointCloud())
        XCTAssertEqual(stats.mean, 0)
        XCTAssertEqual(stats.doubtfulPercent, 0)
    }

    // MARK: - Config wiring

    func testGradingIsOnByDefaultForEveryShippedCaptureProfile() {
        for quality in CaptureQuality.allCases {
            XCTAssertTrue(quality.scanConfig.confidenceGradingEnabled,
                          "\(quality.rawValue) should grade its samples by default")
        }
        XCTAssertTrue(CaptureQuality.objectConfig(fine: true, rangeMeters: 1.5)
            .confidenceGradingEnabled)
    }
}
