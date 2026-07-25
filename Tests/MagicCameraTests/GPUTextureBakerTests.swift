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
            XCTAssertLessThanOrEqual(size, 3072, "never above the sharpness cap")
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

    // MARK: - Multi-page bake cost cap

    /// The page budget must bound the bake's `tris × keyframes × pages` cost so a
    /// big room can't run the multi-page bake past the CPU watchdog (the 2.26 M-pt
    /// / 205 k-tri / 78-kf / 4-page scan iOS killed mid-bake). Every case here is
    /// a real device datapoint. Robust to the memory-gated `surfacePageBudget`.
    func testPageBudgetKeepsWorkingBakesAndCapsTheCrash() {
        // A small mesh's cost never bites — it gets the full area-driven budget.
        XCTAssertEqual(PhotoTextureBaker.affordablePageBudget(triangleCount: 20_000,
                                                              keyframeCount: 30),
                       PhotoTextureBaker.surfacePageBudget,
                       "a light bake keeps the full page budget")
        // The room iOS killed is trimmed to a single sheet it can finish, whatever
        // the device's page budget.
        XCTAssertEqual(PhotoTextureBaker.affordablePageBudget(triangleCount: 204_943,
                                                              keyframeCount: 78), 1,
                       "205k×78 must not attempt multiple pages")
        // And that cap really is a reduction from the requested budget on a
        // multi-page device.
        if PhotoTextureBaker.surfacePageBudget > 1 {
            XCTAssertLessThan(
                PhotoTextureBaker.affordablePageBudget(triangleCount: 204_943, keyframeCount: 78),
                PhotoTextureBaker.surfacePageBudget)
        }
    }

    /// Always at least one page (a single sheet always bakes), never above the
    /// area-driven ceiling, and monotonically non-increasing as the mesh grows.
    func testPageBudgetBoundsAndMonotonicity() {
        XCTAssertGreaterThanOrEqual(
            PhotoTextureBaker.affordablePageBudget(triangleCount: 5_000_000,
                                                   keyframeCount: 96), 1)
        var previous = Int.max
        for tris in stride(from: 20_000, through: 400_000, by: 20_000) {
            let pages = PhotoTextureBaker.affordablePageBudget(triangleCount: tris,
                                                               keyframeCount: 78)
            XCTAssertGreaterThanOrEqual(pages, 1)
            XCTAssertLessThanOrEqual(pages, previous, "more triangles can't buy more pages")
            previous = pages
        }
    }
}
