import XCTest
import ImageIO
@testable import MagicCamera

final class VisionGeometryTests: XCTestCase {
    /// Field by field with a tolerance: `.up` maps every corner to itself, but the
    /// rect is REBUILT from those corners, so the width comes back as
    /// 0.4 − 0.1 = 0.30000000000000004 and exact `CGRect` equality fails on an
    /// identity transform. Nothing to fix in the mapping.
    func testUpIsIdentity() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let mapped = VisionGeometry.nativeNormalizedRect(box, orientation: .up)
        XCTAssertEqual(mapped.minX, box.minX, accuracy: 1e-9)
        XCTAssertEqual(mapped.minY, box.minY, accuracy: 1e-9)
        XCTAssertEqual(mapped.width, box.width, accuracy: 1e-9)
        XCTAssertEqual(mapped.height, box.height, accuracy: 1e-9)
    }

    func testDownFlipsBothAxes() {
        let point = VisionGeometry.nativePoint(CGPoint(x: 0.25, y: 0.10), orientation: .down)
        XCTAssertEqual(point.x, 0.75, accuracy: 1e-6)
        XCTAssertEqual(point.y, 0.90, accuracy: 1e-6)
    }

    func testRightRotation() {
        // native = (1 - oy, ox)
        let point = VisionGeometry.nativePoint(CGPoint(x: 0.2, y: 0.7), orientation: .right)
        XCTAssertEqual(point.x, 0.3, accuracy: 1e-6)
        XCTAssertEqual(point.y, 0.2, accuracy: 1e-6)
    }

    func testLeftRotation() {
        // native = (oy, 1 - ox)
        let point = VisionGeometry.nativePoint(CGPoint(x: 0.2, y: 0.7), orientation: .left)
        XCTAssertEqual(point.x, 0.7, accuracy: 1e-6)
        XCTAssertEqual(point.y, 0.8, accuracy: 1e-6)
    }

    func testRightSwapsBoxAspect() {
        // A tall, thin box on the left of the upright view should become a wide,
        // short box at the bottom of the native (landscape) buffer.
        let oriented = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 1.0)
        let native = VisionGeometry.nativeNormalizedRect(oriented, orientation: .right)
        XCTAssertEqual(native.width, 1.0, accuracy: 1e-6)
        XCTAssertEqual(native.height, 0.2, accuracy: 1e-6)
        XCTAssertEqual(native.minY, 0.0, accuracy: 1e-6)
    }
}
