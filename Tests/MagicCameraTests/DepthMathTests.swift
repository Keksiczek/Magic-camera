import XCTest
import simd
@testable import MagicCamera

final class DepthMathTests: XCTestCase {
    private func makeIntrinsics(fx: Float, fy: Float, cx: Float, cy: Float) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(fx, 0, 0),
            SIMD3<Float>(0, fy, 0),
            SIMD3<Float>(cx, cy, 1)
        ))
    }

    func testScaledIntrinsicsScalesFocalAndPrincipalPoint() {
        let k = makeIntrinsics(fx: 1000, fy: 1000, cx: 960, cy: 720)
        let scaled = DepthMath.scaledIntrinsics(k, imageWidth: 1920, depthWidth: 256)
        let s: Float = 256.0 / 1920.0
        XCTAssertEqual(scaled[0][0], 1000 * s, accuracy: 1e-3)
        XCTAssertEqual(scaled[1][1], 1000 * s, accuracy: 1e-3)
        XCTAssertEqual(scaled[2][0], 960 * s, accuracy: 1e-3)
        XCTAssertEqual(scaled[2][1], 720 * s, accuracy: 1e-3)
    }

    func testCameraLocalPointAtPrincipalPointIsOnAxis() {
        let k = makeIntrinsics(fx: 200, fy: 200, cx: 128, cy: 96)
        // Rays pass through texel centres: index 127.5 + 0.5 == cx.
        let p = DepthMath.cameraLocalPoint(u: 127.5, v: 95.5, depth: 2.0, intrinsics: k)
        XCTAssertEqual(p.x, 0, accuracy: 1e-5)
        XCTAssertEqual(p.y, 0, accuracy: 1e-5)
        XCTAssertEqual(p.z, -2.0, accuracy: 1e-5) // forward is -z in ARKit camera space
    }

    func testCameraLocalPointOffsetByOneFocalLength() {
        let k = makeIntrinsics(fx: 200, fy: 200, cx: 128, cy: 96)
        // u offset by +fx -> x == depth; v offset by +fy -> y == -depth (flipped)
        let p = DepthMath.cameraLocalPoint(u: 327.5, v: 295.5, depth: 3.0, intrinsics: k)
        XCTAssertEqual(p.x, 3.0, accuracy: 1e-4)
        XCTAssertEqual(p.y, -3.0, accuracy: 1e-4)
        XCTAssertEqual(p.z, -3.0, accuracy: 1e-4)
    }

    func testWorldPointWithIdentityTransform() {
        let local = SIMD3<Float>(1, 2, -3)
        let world = DepthMath.worldPoint(cameraLocal: local, cameraTransform: matrix_identity_float4x4)
        XCTAssertEqual(world.x, 1, accuracy: 1e-5)
        XCTAssertEqual(world.y, 2, accuracy: 1e-5)
        XCTAssertEqual(world.z, -3, accuracy: 1e-5)
    }

    func testWorldPointWithTranslation() {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(10, 20, 30, 1)
        let world = DepthMath.worldPoint(cameraLocal: SIMD3<Float>(1, 1, 1), cameraTransform: t)
        XCTAssertEqual(world.x, 11, accuracy: 1e-5)
        XCTAssertEqual(world.y, 21, accuracy: 1e-5)
        XCTAssertEqual(world.z, 31, accuracy: 1e-5)
    }
}
