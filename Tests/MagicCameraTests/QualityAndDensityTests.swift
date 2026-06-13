import XCTest
import simd
@testable import MagicCamera

/// The unified quality engine: profile mappings and the cost estimator.
final class CaptureQualityTests: XCTestCase {

    func testProfilesEscalate() {
        XCTAssertLessThan(CaptureQuality.draft.scanConfig.maxPoints,
                          CaptureQuality.balanced.scanConfig.maxPoints)
        XCTAssertLessThan(CaptureQuality.balanced.scanConfig.maxPoints,
                          CaptureQuality.max.scanConfig.maxPoints)
        XCTAssertEqual(CaptureQuality.draft.reconstructMethod, .voxel)
        XCTAssertEqual(CaptureQuality.max.reconstructMethod, .fusion)
        XCTAssertEqual(CaptureQuality.max.reconstructDetail, .ultra)
    }

    func testMapsFromStoredScanQuality() {
        XCTAssertEqual(CaptureQuality(scanQuality: .fast), .draft)
        XCTAssertEqual(CaptureQuality(scanQuality: .balanced), .balanced)
        XCTAssertEqual(CaptureQuality(scanQuality: .detailed), .max)
        XCTAssertEqual(CaptureQuality(scanQuality: .ultra), .max)
    }

    func testCaptureEstimateScalesWithPoints() {
        let small = QualityEstimator.capture(maxPoints: 300_000)
        let large = QualityEstimator.capture(maxPoints: 1_200_000)
        XCTAssertEqual(small.maxPoints, 300_000)
        XCTAssertGreaterThan(large.memoryMB, small.memoryMB)
        XCTAssertEqual(large.memoryMB, small.memoryMB * 4, accuracy: 0.001)
    }

    func testReconstructionEstimateRisesWithDetail() {
        let cloud = Self.planeCloud(side: 40, spacing: 0.02)   // ~0.8 m square
        let draft = QualityEstimator.reconstruction(cloud: cloud, detail: .draft, method: .voxel)
        let ultra = QualityEstimator.reconstruction(cloud: cloud, detail: .ultra, method: .voxel)
        XCTAssertGreaterThan(ultra.triangles, draft.triangles)
        XCTAssertGreaterThan(draft.memoryMB, 0)
    }

    func testBallPivotEstimateTracksPointCount() {
        let cloud = Self.planeCloud(side: 30, spacing: 0.02)
        let estimate = QualityEstimator.reconstruction(cloud: cloud, detail: .standard, method: .ballPivot)
        XCTAssertEqual(estimate.triangles, Int(Double(cloud.count) * 1.8))
    }

    /// A flat grid of points on the y = 0 plane.
    static func planeCloud(side: Int, spacing: Float) -> PointCloud {
        var cloud = PointCloud()
        for i in 0..<side {
            for j in 0..<side {
                cloud.append(position: SIMD3<Float>(Float(i) * spacing, 0, Float(j) * spacing),
                             color: .one, confidence: 1)
            }
        }
        return cloud
    }
}

/// Curvature estimation and the curvature-weighted thinning.
final class AdaptiveDensityTests: XCTestCase {

    func testPlaneHasLowCurvature() {
        let cloud = CaptureQualityTests.planeCloud(side: 30, spacing: 0.02)
        let curvature = PointCloudCurvature.estimate(cloud)
        let mean = curvature.reduce(0, +) / Float(curvature.count)
        XCTAssertLessThan(mean, 0.05, "a flat plane should read as nearly flat")
    }

    /// The weighting itself: with everything flagged sharp the disk shrinks, so
    /// more points survive than when everything is flat. Independent of the PCA
    /// estimator, so it can't go flaky.
    func testSharpRegionsKeepMorePoints() {
        let cloud = CaptureQualityTests.planeCloud(side: 40, spacing: 0.01)
        let spacing: Float = 0.01
        let flat = PointCloudAdaptiveDownsampler.downsample(
            cloud, curvatures: [Float](repeating: 0, count: cloud.count), spacing: spacing)
        let sharp = PointCloudAdaptiveDownsampler.downsample(
            cloud, curvatures: [Float](repeating: 0.33, count: cloud.count), spacing: spacing)
        XCTAssertGreaterThan(sharp.count, flat.count)
        XCTAssertGreaterThanOrEqual(sharp.count, 1)
    }

    /// keptIndices must be a valid, duplicate-free subset so the reconstruction
    /// pre-pass can carry index-aligned normals/directions through it.
    func testKeptIndicesAreValidSubset() {
        let cloud = CaptureQualityTests.planeCloud(side: 30, spacing: 0.01)
        let curvature = [Float](repeating: 0, count: cloud.count)
        let kept = PointCloudAdaptiveDownsampler.keptIndices(
            cloud, curvatures: curvature, spacing: 0.01)
        XCTAssertLessThan(kept.count, cloud.count)
        XCTAssertTrue(kept.allSatisfy { $0 >= 0 && $0 < cloud.count })
        XCTAssertEqual(Set(kept).count, kept.count)
        XCTAssertEqual(cloud.subset(kept).count, kept.count)
    }

    func testFlatCloudIsThinnedSubstantially() {
        let cloud = CaptureQualityTests.planeCloud(side: 40, spacing: 0.01)   // 1600 pts
        let curvature = [Float](repeating: 0, count: cloud.count)
        let thinned = PointCloudAdaptiveDownsampler.downsample(
            cloud, curvatures: curvature, spacing: 0.01)
        // Flat → spacing × 4, so the plane keeps far fewer than it started with.
        XCTAssertLessThan(thinned.count, cloud.count / 3)
        XCTAssertGreaterThan(thinned.count, 0)
        // Colours/confidence carried through.
        XCTAssertEqual(thinned.colors.count, thinned.count)
        XCTAssertEqual(thinned.confidences.count, thinned.count)
    }
}
