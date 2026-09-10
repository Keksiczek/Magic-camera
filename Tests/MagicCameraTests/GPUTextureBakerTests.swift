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

    /// The page budget is now a page COUNT against live memory headroom, because
    /// that is what the 2026-07-29 device log measured a page to cost: ~865 MB and
    /// ~4-5 s, almost independently of the triangles on it (17 644 tris over
    /// 1 page = 5589 ms; 34 380 over 2 = 3598/4711 ms). Both earlier models —
    /// r67's `tris × kf × pages` and r71's `tris × page` — had the wrong shape.
    ///
    /// It therefore depends on process state, not just its arguments, so these
    /// pin the INVARIANTS rather than specific counts.
    func testPageBudgetStaysWithinItsBounds() {
        for tris in [1_000, 20_000, 204_943, 253_062, 5_000_000] {
            for kf in [2, 30, 96] {
                let pages = PhotoTextureBaker.affordablePageBudget(triangleCount: tris,
                                                                   keyframeCount: kf)
                XCTAssertGreaterThanOrEqual(pages, 1, "a single sheet must always bake")
                XCTAssertLessThanOrEqual(pages, PhotoTextureBaker.surfacePageBudget,
                                         "never above the area-driven ceiling")
            }
        }
    }

    /// Neither triangle count nor keyframe count may change the page budget: the
    /// cost a page carries is the 8192² sheet itself (gutter fill over 67 M
    /// texels, seam levelling, encode), and the memory it needs is the photo
    /// array plus the atlas buffers — none of which scale with the geometry.
    ///
    /// This is the regression guard for the bug that shipped at r67 and cost the
    /// texture 2×: a 253k-tri room over 75 keyframes scored 19 M against a 16 M
    /// ceiling on the FIXED scoring term alone, so it could never afford a second
    /// page and shipped at a measured 2.63 mm/texel.
    func testPageBudgetIgnoresGeometryAndKeyframeCount() {
        let reference = PhotoTextureBaker.affordablePageBudget(triangleCount: 253_062,
                                                               keyframeCount: 75)
        for tris in [1_000, 50_000, 253_062, 1_000_000] {
            for kf in [1, 8, 75, 200] {
                XCTAssertEqual(
                    PhotoTextureBaker.affordablePageBudget(triangleCount: tris, keyframeCount: kf),
                    reference,
                    "page budget must not vary with \(tris) tris / \(kf) kf")
            }
        }
    }
}
