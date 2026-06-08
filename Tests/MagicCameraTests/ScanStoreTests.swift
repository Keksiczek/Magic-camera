import XCTest
import simd
@testable import MagicCamera

final class ScanStoreTests: XCTestCase {
    func testSaveLoadRoundTrip() throws {
        var cloud = PointCloud()
        cloud.append(position: SIMD3<Float>(1, 2, 3), color: SIMD3<Float>(1, 0, 0), confidence: 1)
        cloud.append(position: SIMD3<Float>(-4, 5, -6), color: SIMD3<Float>(0, 0.5, 1), confidence: 0.5)

        let name = "UnitTest-\(UUID().uuidString)"
        let url = try ScanStore.save(cloud, name: name)
        defer { ScanStore.delete(url) }

        let loaded = try ScanStore.load(url)
        XCTAssertEqual(loaded.count, cloud.count)
        XCTAssertEqual(loaded.positions[1], SIMD3<Float>(-4, 5, -6))
        XCTAssertEqual(loaded.colors[0], SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(loaded.confidences[1], 0.5, accuracy: 1e-6)
    }

    func testListIncludesSavedScan() throws {
        var cloud = PointCloud()
        cloud.append(position: .zero, color: .zero, confidence: 1)
        let name = "UnitTestList-\(UUID().uuidString)"
        let url = try ScanStore.save(cloud, name: name)
        defer { ScanStore.delete(url) }

        let listed = ScanStore.list()
        XCTAssertTrue(listed.contains { $0.url == url && $0.pointCount == 1 })
    }
}

final class ScanQualityTests: XCTestCase {
    func testQualityOrderingMakesSense() {
        let fast = ScanQuality.fast.config
        let balanced = ScanQuality.balanced.config
        let detailed = ScanQuality.detailed.config
        XCTAssertGreaterThan(detailed.maxPoints, balanced.maxPoints)
        XCTAssertGreaterThan(balanced.maxPoints, fast.maxPoints)
        XCTAssertLessThan(detailed.voxelSize, balanced.voxelSize)
        XCTAssertLessThan(balanced.voxelSize, fast.voxelSize)
    }
}

final class MeshExporterTests: XCTestCase {
    func testEmptyMeshThrows() {
        XCTAssertThrowsError(try MeshExporter.write(MeshData(), format: .obj))
    }

    func testMeshDataBoundingBox() {
        var mesh = MeshData()
        mesh.vertices = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 4, 6)]
        mesh.normals = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)]
        mesh.indices = [0, 1, 0]
        let box = mesh.boundingBox()
        XCTAssertEqual(box?.min, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(box?.max, SIMD3<Float>(2, 4, 6))
        XCTAssertEqual(mesh.triangleCount, 1)
    }
}

final class MeshStoreTests: XCTestCase {
    func testSaveLoadRoundTripWithClassification() throws {
        let mesh = MeshData(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 2, 3), SIMD3<Float>(-4, 5, -6)],
            normals: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 1)],
            indices: [0, 1, 2],
            classifications: [MeshClassification.floor.rawValue,
                              MeshClassification.wall.rawValue,
                              MeshClassification.table.rawValue])

        let name = "UnitTestMesh-\(UUID().uuidString)"
        let url = try MeshStore.save(mesh, name: name)
        defer { MeshStore.delete(url) }

        let loaded = try MeshStore.load(url)
        XCTAssertEqual(loaded.vertices, mesh.vertices)
        XCTAssertEqual(loaded.normals, mesh.normals)
        XCTAssertEqual(loaded.indices, mesh.indices)
        XCTAssertEqual(loaded.classifications, mesh.classifications)
        XCTAssertTrue(loaded.hasClassification)
        XCTAssertEqual(loaded.triangleCount, 1)
    }

    func testSaveLoadRoundTripWithoutClassification() throws {
        let mesh = MeshData(
            vertices: [SIMD3<Float>(0.5, -0.5, 1.5), SIMD3<Float>(2, 2, 2), SIMD3<Float>(3, 1, 4)],
            normals: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)],
            indices: [0, 1, 2])

        let name = "UnitTestMeshPlain-\(UUID().uuidString)"
        let url = try MeshStore.save(mesh, name: name)
        defer { MeshStore.delete(url) }

        let loaded = try MeshStore.load(url)
        XCTAssertEqual(loaded.vertices, mesh.vertices)
        XCTAssertEqual(loaded.indices, mesh.indices)
        XCTAssertFalse(loaded.hasClassification)
    }

    func testLibraryListsSavedMesh() throws {
        let mesh = MeshData(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1), SIMD3<Float>(2, 0, 1)],
            normals: [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)],
            indices: [0, 1, 2])
        let name = "UnitTestLib-\(UUID().uuidString)"
        let url = try MeshStore.save(mesh, name: name)
        defer { MeshStore.delete(url) }

        let items = ScanLibrary.allItems()
        XCTAssertTrue(items.contains { $0.url == url && $0.kind == .mesh && $0.count == 1 })
    }
}
