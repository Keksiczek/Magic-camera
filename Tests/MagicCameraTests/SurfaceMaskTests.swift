//
//  SurfaceMaskTests.swift
//  MagicCameraTests
//
//  Covers the ARKit scene-mesh cleanup used on Object scans: masking the cloud
//  to a reference surface (dropping silhouette floaters), reading the floor
//  level from a classified mesh, and cropping above it.
//

import XCTest
import simd
@testable import MagicCamera

final class SurfaceMaskTests: XCTestCase {

    // MARK: - Fixtures

    /// A 20×20 vertex grid at y = 0.5 standing in for ARKit's regularised
    /// surface, with two throwaway triangles so `isEmpty` is false.
    private func referenceSurface(classifyAsFloor: Bool = false) -> MeshData {
        var vertices: [SIMD3<Float>] = []
        for x in 0..<20 {
            for z in 0..<20 {
                vertices.append(SIMD3<Float>(Float(x) * 0.02, 0.5, Float(z) * 0.02))
            }
        }
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: vertices.count)
        let indices: [UInt32] = [0, 1, 2, 1, 2, 3]
        let classes: [UInt8] = classifyAsFloor
            ? [UInt8](repeating: MeshClassification.floor.rawValue, count: vertices.count)
            : []
        return MeshData(vertices: vertices, normals: normals, indices: indices,
                        classifications: classes)
    }

    /// On-surface points (should survive a mask) plus floaters 0.5 m above the
    /// surface (the silhouette bleed a mask must remove).
    private func cloudOnAndOffSurface() -> (cloud: PointCloud, onSurface: Int) {
        var cloud = PointCloud()
        var onSurface = 0
        for x in 0..<10 {
            for z in 0..<10 {
                cloud.append(position: SIMD3<Float>(Float(x) * 0.02, 0.5, Float(z) * 0.02),
                             color: SIMD3<Float>(0.8, 0.2, 0.2), confidence: 1)
                onSurface += 1
            }
        }
        // 100 floaters hanging 0.5 m off any real surface.
        for i in 0..<100 {
            cloud.append(position: SIMD3<Float>(Float(i) * 0.002, 1.0, 0.05),
                         color: SIMD3<Float>(0.2, 0.8, 0.2), confidence: 1)
        }
        return (cloud, onSurface)
    }

    // MARK: - Masking

    func testMaskKeepsSurfacePointsAndDropsFloaters() throws {
        let (cloud, onSurface) = cloudOnAndOffSurface()
        let masked = try XCTUnwrap(
            SurfaceMask.maskToSurface(cloud, surface: referenceSurface(), tolerance: 0.03))
        XCTAssertEqual(masked.count, onSurface,
                       "every on-surface point survives, every floater is dropped")
        for i in 0..<masked.count {
            XCTAssertEqual(masked.positions[i].y, 0.5, accuracy: 0.001)
        }
    }

    func testMaskReturnsNilWhenItWouldGutTheCloud() {
        // A surface far from the cloud keeps nothing → nil so the caller falls
        // back to the raw cloud instead of returning an empty one.
        let farSurface = MeshData(
            vertices: [SIMD3<Float>(50, 50, 50), SIMD3<Float>(50.02, 50, 50),
                       SIMD3<Float>(50, 50.02, 50)],
            normals: [SIMD3<Float>](repeating: .init(0, 1, 0), count: 3),
            indices: [0, 1, 2])
        let (cloud, _) = cloudOnAndOffSurface()
        XCTAssertNil(SurfaceMask.maskToSurface(cloud, surface: farSurface, tolerance: 0.03))
    }

    func testMaskIsNoOpWithoutSurface() {
        let (cloud, _) = cloudOnAndOffSurface()
        // `cleaned` with no surface returns the cloud untouched.
        let result = SurfaceMask.cleaned(cloud, using: nil)
        XCTAssertEqual(result.count, cloud.count)
    }

    // MARK: - Floor

    func testFloorLevelFromClassifiedMesh() throws {
        var surface = referenceSurface(classifyAsFloor: true)
        // Shift the classified floor grid to y = 0 so the level is unambiguous.
        surface.vertices = surface.vertices.map { SIMD3<Float>($0.x, 0, $0.z) }
        let floorY = try XCTUnwrap(SurfaceMask.floorLevel(of: surface))
        XCTAssertEqual(floorY, 0, accuracy: 0.001)
    }

    func testFloorLevelNilWithoutClassification() {
        XCTAssertNil(SurfaceMask.floorLevel(of: referenceSurface(classifyAsFloor: false)))
    }

    func testCroppingAboveDropsFloor() {
        var cloud = PointCloud()
        // Floor slab at y = 0.
        for i in 0..<100 {
            cloud.append(position: SIMD3<Float>(Float(i) * 0.01, 0, 0),
                         color: .init(repeating: 0.5), confidence: 1)
        }
        // Subject above at y = 0.2.
        for i in 0..<100 {
            cloud.append(position: SIMD3<Float>(Float(i) * 0.01, 0.2, 0),
                         color: .init(repeating: 0.9), confidence: 1)
        }
        let cropped = SurfaceMask.croppingAbove(cloud, floorY: 0, tolerance: 0.02)
        XCTAssertEqual(cropped.count, 100, "the floor slab is removed, the subject kept")
        for i in 0..<cropped.count {
            XCTAssertGreaterThan(cropped.positions[i].y, 0.02)
        }
    }
}
