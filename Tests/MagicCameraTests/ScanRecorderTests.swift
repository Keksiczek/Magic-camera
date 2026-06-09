//
//  ScanRecorderTests.swift
//  MagicCameraTests
//
//  Tests the pure, ARKit-free pieces of the recorder: distance-adaptive voxel
//  snapping and the scan-coverage estimator. (Frame processing itself needs a
//  live ARFrame and is covered by manual QA.)
//
import XCTest
import simd
@testable import MagicCamera

final class ScanRecorderTests: XCTestCase {

    // MARK: - Adaptive voxel snapping

    func testAdaptiveSnapLeavesNearPointsUntouched() {
        let config = ScanConfig()   // near distance 1.5 m, enabled
        let p = SIMD3<Float>(0.005, 0.123, -0.04)
        let snapped = ScanRecorder.adaptiveSnap(p, cameraDistance: 1.0,
                                                voxelSize: 0.012, config: config)
        XCTAssertEqual(snapped, p)
    }

    func testAdaptiveSnapCoarsensDistantPoints() {
        // At 4 m the multiplier is 3 (cell = 0.036 m), so two points 0.01 m apart
        // collapse onto the same coarse lattice cell — the density reduction we want.
        let config = ScanConfig()
        let a = ScanRecorder.adaptiveSnap(SIMD3<Float>(0.005, 0, 0), cameraDistance: 4.0,
                                          voxelSize: 0.012, config: config)
        let b = ScanRecorder.adaptiveSnap(SIMD3<Float>(0.015, 0, 0), cameraDistance: 4.0,
                                          voxelSize: 0.012, config: config)
        XCTAssertEqual(a, b)
    }

    func testAdaptiveSnapDisabledLeavesPointsUntouched() {
        var config = ScanConfig()
        config.adaptiveVoxelEnabled = false
        let p = SIMD3<Float>(0.005, 0, 0)
        let snapped = ScanRecorder.adaptiveSnap(p, cameraDistance: 5.0,
                                                voxelSize: 0.012, config: config)
        XCTAssertEqual(snapped, p)
    }

    func testAdaptiveSnapRespectsMaxMultiplier() {
        // Very far points clamp to the max multiplier (4 → cell 0.048 m).
        let config = ScanConfig()
        let snapped = ScanRecorder.adaptiveSnap(SIMD3<Float>(0.1, 0, 0), cameraDistance: 50.0,
                                                voxelSize: 0.012, config: config)
        // 0.1 / 0.048 = 2.08 → rounds to 2 → 0.096
        XCTAssertEqual(snapped.x, 0.096, accuracy: 1e-4)
    }

    // MARK: - Coverage estimator

    func testCoverageReturnsNilWhileWarmingUp() {
        var estimator = ScanCoverageEstimator()   // warmup 2000 points
        XCTAssertNil(estimator.update(totalCount: 100))
        XCTAssertNil(estimator.update(totalCount: 1500))
    }

    func testCoverageRisesAsGrowthFlattens() {
        var estimator = ScanCoverageEstimator()
        // Ramp past warmup with large deltas — actively discovering surface.
        _ = estimator.update(totalCount: 1000)
        _ = estimator.update(totalCount: 2000)
        _ = estimator.update(totalCount: 3000)
        let duringGrowth = estimator.update(totalCount: 4000)
        XCTAssertNotNil(duringGrowth)

        // Plateau: no new points for a while → growth decays → coverage approaches 1.
        for _ in 0..<25 { _ = estimator.update(totalCount: 4000) }
        let saturated = estimator.update(totalCount: 4000)
        XCTAssertNotNil(saturated)
        XCTAssertGreaterThan(saturated!, 0.9)
        XCTAssertLessThan(duringGrowth!, saturated!)
    }

    func testCoverageResetClearsState() {
        var estimator = ScanCoverageEstimator()
        for c in stride(from: 1000, through: 6000, by: 500) { _ = estimator.update(totalCount: c) }
        estimator.reset()
        // After reset we are warming up again from zero.
        XCTAssertNil(estimator.update(totalCount: 100))
    }
}
