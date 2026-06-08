import XCTest
import simd
@testable import MagicCamera

final class PointCloudTests: XCTestCase {
    func testAppendAndCount() {
        var cloud = PointCloud()
        XCTAssertTrue(cloud.isEmpty)
        cloud.append(position: SIMD3<Float>(1, 2, 3), color: SIMD3<Float>(1, 0, 0), confidence: 1)
        cloud.append(position: SIMD3<Float>(-1, 0, 5), color: SIMD3<Float>(0, 1, 0), confidence: 0.5)
        XCTAssertEqual(cloud.count, 2)
        XCTAssertEqual(cloud.positions[0], SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(cloud.confidences[1], 0.5)
    }

    func testBoundingBoxAndCentroid() {
        var cloud = PointCloud()
        cloud.append(position: SIMD3<Float>(0, 0, 0), color: .zero, confidence: 1)
        cloud.append(position: SIMD3<Float>(2, 4, 6), color: .zero, confidence: 1)
        let box = cloud.boundingBox()
        XCTAssertEqual(box?.min, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(box?.max, SIMD3<Float>(2, 4, 6))
        XCTAssertEqual(cloud.centroid(), SIMD3<Float>(1, 2, 3))
    }

    func testRemoveAll() {
        var cloud = PointCloud()
        cloud.append(position: .zero, color: .zero, confidence: 1)
        cloud.removeAll()
        XCTAssertTrue(cloud.isEmpty)
        XCTAssertNil(cloud.boundingBox())
    }

    func testVoxelGridDeduplicates() {
        var grid = VoxelGrid(voxelSize: 0.1)
        XCTAssertTrue(grid.insert(SIMD3<Float>(0.00, 0.00, 0.00)))
        XCTAssertFalse(grid.insert(SIMD3<Float>(0.05, 0.05, 0.05))) // same voxel
        XCTAssertTrue(grid.insert(SIMD3<Float>(0.20, 0.00, 0.00)))  // different voxel
        XCTAssertEqual(grid.occupiedCount, 2)
    }

    func testVoxelNeighborCountDetectsIsolatedPoints() {
        var grid = VoxelGrid(voxelSize: 0.1)
        // A small cluster of adjacent voxels.
        _ = grid.insert(SIMD3<Float>(0.00, 0, 0))
        _ = grid.insert(SIMD3<Float>(0.10, 0, 0))
        _ = grid.insert(SIMD3<Float>(0.20, 0, 0))
        // An isolated point far away.
        _ = grid.insert(SIMD3<Float>(5.0, 5.0, 5.0))

        XCTAssertGreaterThanOrEqual(grid.occupiedNeighborCount(of: SIMD3<Float>(0.10, 0, 0)), 3)
        XCTAssertEqual(grid.occupiedNeighborCount(of: SIMD3<Float>(5.0, 5.0, 5.0)), 1)
    }
}
