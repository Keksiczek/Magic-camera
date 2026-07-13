//
//  PointCloudVisibilityFilterTests.swift
//  MagicCameraTests
//
//  Verifies the finish-time multi-view visibility trim: free-space bleed that
//  several pose-diverse views saw through is dropped, while surface, occluded
//  geometry, thin structure (neighbour-texel rescue) and the no-parallax case
//  are kept. Synthetic wall + aimed camera arc with analytic depth maps.
//
import XCTest
import simd
@testable import MagicCamera

final class PointCloudVisibilityFilterTests: XCTestCase {

    private let width = 64, height = 48
    private let fx: Float = 36, fy: Float = 36, cx: Float = 32, cy: Float = 24
    private let wallZ: Float = -3.0
    private let target = SIMD3<Float>(0.1, 1.1, -1.5)

    /// Camera at `position` aimed at `target` (yaw only; camera looks down
    /// −z_world at yaw 0, look_world = (−sin, 0, −cos)). The depth map is the
    /// analytic camera-z distance to the wall plane z = wallZ.
    private func makeView(position: SIMD3<Float>) -> PointCloudVisibilityFilter.DepthView {
        let look = simd_normalize(target - position)
        let yaw = atan2(-look.x, -look.z)
        let c = cos(yaw), s = sin(yaw)
        let rotation = simd_float3x3(SIMD3(c, 0, -s), SIMD3(0, 1, 0), SIMD3(s, 0, c))
        let cameraToWorld = simd_float4x4(SIMD4(rotation.columns.0, 0),
                                          SIMD4(rotation.columns.1, 0),
                                          SIMD4(rotation.columns.2, 0),
                                          SIMD4(position, 1))
        var depth = [Float](repeating: 0, count: width * height)
        for v in 0..<height {
            for u in 0..<width {
                let direction = rotation * SIMD3<Float>((Float(u) + 0.5 - cx) / fx,
                                                        -(Float(v) + 0.5 - cy) / fy,
                                                        -1)
                guard abs(direction.z) > 1e-6 else { continue }
                let t = (wallZ - position.z) / direction.z
                if t > 0 { depth[v * width + u] = t }
            }
        }
        return .init(worldToCamera: cameraToWorld.inverse, fx: fx, fy: fy, cx: cx, cy: cy,
                     width: width, height: height, depth: depth)
    }

    private func arcViews() -> [PointCloudVisibilityFilter.DepthView] {
        (0..<7).map { makeView(position: SIMD3(Float($0 - 3) * 0.4, 1.2, 0)) }
    }

    /// Projected pixel of `p` in `view`, for corrupting specific texels.
    private func pixel(of p: SIMD3<Float>,
                       in view: PointCloudVisibilityFilter.DepthView) -> (Int, Int, Float)? {
        let pc = view.worldToCamera * SIMD4<Float>(p, 1)
        let d = -pc.z
        guard d > 0.05 else { return nil }
        let u = pc.x / d * view.fx + view.cx
        let v = -pc.y / d * view.fy + view.cy
        guard u >= 1, v >= 1, u < Float(view.width - 1), v < Float(view.height - 1) else { return nil }
        return (Int(u), Int(v), d)
    }

    private func corrupt(_ view: PointCloudVisibilityFilter.DepthView,
                         at index: Int, to value: Float) -> PointCloudVisibilityFilter.DepthView {
        var depth = view.depth
        depth[index] = value
        return .init(worldToCamera: view.worldToCamera, fx: view.fx, fy: view.fy,
                     cx: view.cx, cy: view.cy, width: view.width, height: view.height,
                     depth: depth)
    }

    // MARK: - Verdicts

    func testSurfacePointKept() {
        let onWall = SIMD3<Float>(0.3, 1.0, wallZ)
        XCTAssertEqual(PointCloudVisibilityFilter.keepMask(positions: [onWall],
                                                           views: arcViews()), [true])
    }

    func testFreeSpaceBleedDropped() {
        XCTAssertEqual(PointCloudVisibilityFilter.keepMask(positions: [target],
                                                           views: arcViews()), [false])
    }

    func testSingleSupportStillDropped() throws {
        // One camera's depth map carries the flying pixel itself (that is how
        // the bleed got fused) — one support must not save it.
        var views = arcViews()
        let (u, v, d) = try XCTUnwrap(pixel(of: target, in: views[3]))
        views[3] = corrupt(views[3], at: v * width + u, to: d)
        XCTAssertEqual(PointCloudVisibilityFilter.keepMask(positions: [target],
                                                           views: views), [false])
    }

    func testSelfVotedBleedStillDropped() throws {
        // The captured wing's own keyframes carry its flying pixels — two
        // self-supports must lose to five clean see-throughs (2× outvote).
        var views = arcViews()
        for k in [2, 4] {
            let (u, v, d) = try XCTUnwrap(pixel(of: target, in: views[k]))
            views[k] = corrupt(views[k], at: v * width + u, to: d)
        }
        XCTAssertEqual(PointCloudVisibilityFilter.keepMask(positions: [target],
                                                           views: views), [false])
    }

    func testMajoritySupportsKeep() throws {
        var views = arcViews()
        for k in [1, 2, 4, 5] {
            let (u, v, d) = try XCTUnwrap(pixel(of: target, in: views[k]))
            views[k] = corrupt(views[k], at: v * width + u, to: d)
        }
        XCTAssertEqual(PointCloudVisibilityFilter.keepMask(positions: [target],
                                                           views: views), [true])
    }

    func testOccludedRealGeometryKept() {
        // Behind the wall: every view sees the wall in FRONT of it — no
        // evidence either way, so it must survive.
        let hidden = SIMD3<Float>(0.2, 1.0, -4.0)
        XCTAssertEqual(PointCloudVisibilityFilter.keepMask(positions: [hidden],
                                                           views: arcViews()), [true])
    }

    func testThinStructureRescuedByNeighbourTexel() throws {
        // Centre texel reads the background beside a thin strand (the ray-
        // through-gap quantisation that once shredded the wicker chair), but
        // a neighbouring texel catches the strand in most near views — those
        // rescues become supports the remaining gap-rays can't outvote.
        var views = arcViews()
        for k in [0, 2, 4, 6] {
            let (u, v, d) = try XCTUnwrap(pixel(of: target, in: views[k]))
            views[k] = corrupt(views[k], at: v * width + (u + 1), to: d)
        }
        XCTAssertEqual(PointCloudVisibilityFilter.keepMask(positions: [target],
                                                           views: views), [true])
    }

    func testNoParallaxKeepsItsOwnBleed() throws {
        // Standing still: every "view" is the same pose whose map contains
        // the mixed pixel. No parallax → no verdict → kept (physics limit).
        let base = makeView(position: SIMD3(0, 1.2, 0))
        let (u, v, d) = try XCTUnwrap(pixel(of: target, in: base))
        let still = corrupt(base, at: v * width + u, to: d)
        let mask = PointCloudVisibilityFilter.keepMask(positions: [target],
                                                       views: Array(repeating: still, count: 7))
        XCTAssertEqual(mask, [true])
    }

    func testFewViewsIsNoOp() {
        let few = Array(arcViews().prefix(PointCloudVisibilityFilter.minViews - 1))
        XCTAssertEqual(PointCloudVisibilityFilter.keepMask(positions: [target],
                                                           views: few), [true])
    }

    // MARK: - Cloud plumbing

    func testTrimFiltersCloudAndDirectionsInLockstep() {
        var cloud = PointCloud()
        cloud.append(position: SIMD3(0.3, 1.0, wallZ), color: SIMD3(1, 0, 0), confidence: 1)
        cloud.append(position: target, color: SIMD3(0, 1, 0), confidence: 1)   // bleed
        cloud.append(position: SIMD3(-0.2, 0.9, wallZ), color: SIMD3(0, 0, 1), confidence: 1)
        let directions: [SIMD3<Float>] = [SIMD3(0, 0, -1), SIMD3(0, 0, -1), SIMD3(0, 0, -1)]
        let result = PointCloudVisibilityFilter.trim(cloud, viewDirections: directions,
                                                     views: arcViews())
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.cloud.count, 2)
        XCTAssertEqual(result.viewDirections.count, 2)
        XCTAssertEqual(result.cloud.colors[0], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(result.cloud.colors[1], SIMD3<Float>(0, 0, 1))
    }
}
