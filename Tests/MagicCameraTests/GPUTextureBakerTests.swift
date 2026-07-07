//
//  GPUTextureBakerTests.swift
//  MagicCameraTests
//
//  The GPU bake's per-keyframe sampling slice is sized adaptively so the r22
//  hi-res keyframes aren't squashed to 1024² (the texture softness ceiling) while
//  the sampling texture array (N × slice² × 4 bytes) stays under its memory
//  budget. The exact value is memory-gated, but the bounds / stepping /
//  monotonicity hold on any device.
//

import XCTest
@testable import MagicCamera

final class GPUTextureBakerTests: XCTestCase {

    func testSliceSizeStaysWithinBounds() {
        for n in [1, 4, 8, 16, 24, 32, 48, 64] {
            let size = GPUTextureBaker.sliceSize(forKeyframeCount: n)
            XCTAssertGreaterThanOrEqual(size, 1024, "never below the baseline")
            XCTAssertLessThanOrEqual(size, 2048, "never above the sharpness cap")
            XCTAssertEqual(size % 256, 0, "stepped to a clean multiple")
        }
    }

    func testZeroKeyframesGuards() {
        XCTAssertEqual(GPUTextureBaker.sliceSize(forKeyframeCount: 0), 1024)
    }

    /// More keyframes must never grow the slice — the per-array budget shrinks the
    /// square as N rises, so the total (N × slice² × 4) can't run away and OOM.
    func testSliceSizeNonIncreasingInKeyframeCount() {
        var previous = GPUTextureBaker.sliceSize(forKeyframeCount: 1)
        for n in 1...64 {
            let size = GPUTextureBaker.sliceSize(forKeyframeCount: n)
            XCTAssertLessThanOrEqual(size, previous)
            previous = size
        }
    }
}
