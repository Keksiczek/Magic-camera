import XCTest
import Foundation
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

/// Consistent normal orientation (MST flood-fill) for reconstruction.
final class NormalOrientationTests: XCTestCase {

    /// Evenly distributed points on a sphere (Fibonacci lattice).
    private func sphere(_ n: Int, radius: Float) -> [SIMD3<Float>] {
        let golden = Float.pi * (3 - Float(5).squareRoot())
        var points: [SIMD3<Float>] = []
        for i in 0..<n {
            let y = 1 - 2 * Float(i) / Float(max(n - 1, 1))
            let ring = max(0, 1 - y * y).squareRoot()
            let theta = golden * Float(i)
            points.append(SIMD3<Float>(cos(theta) * ring, y, sin(theta) * ring) * radius)
        }
        return points
    }

    /// Radial normals with half of them flipped should be made coherent and
    /// outward again — that's exactly what ball-pivot/smooth rely on.
    func testOrientationRecoversOutwardNormals() {
        let positions = sphere(700, radius: 0.2)
        var normals = positions.map { simd_normalize($0) }
        var seed: UInt64 = 0x9E37
        for i in 0..<normals.count {
            seed = seed &* 6364136223846793005 &+ 1
            if (seed >> 40) & 1 == 0 { normals[i] = -normals[i] }
        }
        let oriented = PointCloudNormals.orientConsistently(normals, positions: positions)
        var outward = 0
        for i in 0..<positions.count where simd_dot(oriented[i], simd_normalize(positions[i])) > 0 {
            outward += 1
        }
        XCTAssertGreaterThan(Float(outward) / Float(positions.count), 0.9)
    }

    func testEstimateConsistentOnSphereIsOutward() {
        let positions = sphere(700, radius: 0.2)
        var cloud = PointCloud()
        for p in positions { cloud.append(position: p, color: .one, confidence: 1) }
        let normals = PointCloudNormals.estimateConsistent(cloud)
        var outward = 0
        for i in 0..<positions.count where simd_dot(normals[i], simd_normalize(positions[i])) > 0 {
            outward += 1
        }
        XCTAssertGreaterThan(Float(outward) / Float(positions.count), 0.85)
    }

    /// The cost guard returns the input untouched above the point ceiling.
    func testOrientationRespectsSizeGuard() {
        let positions = sphere(10, radius: 0.1)
        let normals = positions.map { simd_normalize($0) }
        let out = PointCloudNormals.orientConsistently(normals, positions: positions, maxPoints: 5)
        XCTAssertEqual(out, normals)
    }
}
