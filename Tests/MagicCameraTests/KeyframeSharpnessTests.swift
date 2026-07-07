//
//  KeyframeSharpnessTests.swift
//  MagicCameraTests
//
//  Keyframe sharpness scoring feeds the bake's view weighting (crisp keyframes
//  win) and survives the .mckeys sidecar round-trip (so a reopened scan
//  re-textures with the same preference).
//

import XCTest
import simd
@testable import MagicCamera

final class KeyframeSharpnessTests: XCTestCase {

    // MARK: - Relative weights

    func testEqualSharpnessWeighsUniformly() {
        let w = KeyframeSharpness.weights(for: [5, 5, 5, 5])
        XCTAssertEqual(w.count, 4)
        for x in w { XCTAssertEqual(x, w[0], accuracy: 1e-6) }
    }

    func testSharperKeyframeWeighsMore() {
        let w = KeyframeSharpness.weights(for: [10, 1])
        XCTAssertGreaterThan(w[0], w[1])
    }

    func testWeightsAreBoundedAndMonotonic() {
        let sharps: [Float] = [0, 0.5, 1, 2, 5, 20, 100]
        let w = KeyframeSharpness.weights(for: sharps)
        var previous: Float = 0
        for (i, x) in w.enumerated() {
            XCTAssertGreaterThanOrEqual(x, 0.5)
            XCTAssertLessThanOrEqual(x, 1.0)
            if i > 0 { XCTAssertGreaterThanOrEqual(x, previous) }   // sharper ⇒ not lower
            previous = x
        }
    }

    func testEmptyIsEmpty() {
        XCTAssertTrue(KeyframeSharpness.weights(for: []).isEmpty)
    }

    // MARK: - Sidecar persistence

    private func makeKeyframe(sharpness: Float) -> ScanKeyframe {
        ScanKeyframe(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                     cameraTransform: matrix_identity_float4x4,
                     intrinsics: matrix_identity_float3x3,
                     depthWidth: 2, depthHeight: 2,
                     depth: [1, 1, 1, 1], sharpness: sharpness)
    }

    func testSharpnessSurvivesRoundTrip() {
        let keyframes = [makeKeyframe(sharpness: 42.5), makeKeyframe(sharpness: 3.25)]
        let decoded = ScanKeyframeStore.decode(ScanKeyframeStore.encode(keyframes))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].sharpness, 42.5, accuracy: 1e-4)
        XCTAssertEqual(decoded[1].sharpness, 3.25, accuracy: 1e-4)
    }
}
