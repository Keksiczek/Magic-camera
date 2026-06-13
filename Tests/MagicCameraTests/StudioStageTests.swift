import XCTest
import simd
@testable import MagicCamera

/// Round-trip of the .mcstage project format.
final class StageStoreTests: XCTestCase {

    private func sampleObjects() -> [StudioObject] {
        [
            StudioObject(name: "Kostka č. 1",
                         mesh: PrimitiveMesher.mesh(.box, size: SIMD3(0.2, 0.3, 0.4)),
                         color: SIMD3(0.9, 0.25, 0.22), colorName: "red", revision: 1),
            StudioObject(name: "Sphere",
                         mesh: PrimitiveMesher.mesh(.sphere, size: SIMD3(0.2, 0.2, 0.2)),
                         color: SIMD3(0.28, 0.51, 0.92), colorName: "blue", revision: 2),
        ]
    }

    func testStageRoundTrip() throws {
        let objects = sampleObjects()
        let name = "UnitTestStage-\(UUID().uuidString)"
        let url = try StageStore.save(objects, name: name)
        defer { StageStore.delete(url) }

        let loaded = try StageStore.load(url)
        XCTAssertEqual(loaded.count, objects.count)
        for (stored, original) in zip(loaded, objects) {
            XCTAssertEqual(stored.name, original.name)
            XCTAssertEqual(stored.colorName, original.colorName)
            XCTAssertEqual(stored.color, original.color)
            XCTAssertEqual(stored.mesh.vertices, original.mesh.vertices)
            XCTAssertEqual(stored.mesh.normals, original.mesh.normals)
            XCTAssertEqual(stored.mesh.indices, original.mesh.indices)
        }
    }

    func testListIncludesSavedStage() throws {
        let name = "UnitTestStageList-\(UUID().uuidString)"
        let url = try StageStore.save(sampleObjects(), name: name)
        defer { StageStore.delete(url) }

        XCTAssertTrue(StageStore.list().contains { $0.url == url && $0.objectCount == 2 })
    }

    func testCorruptDataThrows() {
        XCTAssertThrowsError(try StageStore.decode(Data([1, 2, 3])))
        XCTAssertThrowsError(try StageStore.decode(Data(count: 64)))
    }
}

/// Voxel CSG sanity: volumes of box⋃box / box−box / box⋂box against the
/// analytic values, computed from the signed volume so inverted winding in
/// the marching-cubes output would fail too.
final class MeshBooleanTests: XCTestCase {

    private func signedVolume(_ mesh: MeshData) -> Float {
        var sixV: Float = 0
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[i])]
            let b = mesh.vertices[Int(mesh.indices[i + 1])]
            let c = mesh.vertices[Int(mesh.indices[i + 2])]
            sixV += simd_dot(a, simd_cross(b, c))
            i += 3
        }
        return sixV / 6
    }

    private func box(offsetX: Float) -> MeshData {
        PrimitiveMesher.mesh(.box, size: SIMD3(0.2, 0.2, 0.2))
            .transformed(by: ModelStudioViewModel.translation(SIMD3(offsetX, 0, 0)))
    }

    /// Two 0.2 m boxes overlapping by half: union 0.012 m³, subtract and
    /// intersect 0.004 m³ each.
    func testBooleanVolumesOfOverlappingBoxes() throws {
        let a = box(offsetX: 0)
        let b = box(offsetX: 0.1)
        let cases: [(MeshBoolean.Operation, Float)] = [
            (.union, 0.012), (.subtract, 0.004), (.intersect, 0.004),
        ]
        for (operation, expected) in cases {
            let result = try XCTUnwrap(MeshBoolean.combine(a, b, operation: operation),
                                       "\(operation.rawValue) returned nil")
            let volume = signedVolume(result)
            XCTAssertGreaterThan(volume, 0, "\(operation.rawValue) wound inward")
            XCTAssertEqual(volume, expected, accuracy: expected * 0.12,
                           "\(operation.rawValue) volume off")
        }
    }

    func testDisjointIntersectionIsNil() {
        XCTAssertNil(MeshBoolean.combine(box(offsetX: 0), box(offsetX: 1),
                                         operation: .intersect))
    }

    /// Subtracting something far away must leave the original volume.
    func testDisjointSubtractKeepsOriginal() throws {
        let result = try XCTUnwrap(MeshBoolean.combine(box(offsetX: 0), box(offsetX: 1),
                                                       operation: .subtract))
        XCTAssertEqual(signedVolume(result), 0.008, accuracy: 0.008 * 0.12)
    }

    func testOperationParsingAcceptsSynonyms() {
        XCTAssertEqual(MeshBoolean.Operation.parse("Carve"), .subtract)
        XCTAssertEqual(MeshBoolean.Operation.parse("join"), .union)
        XCTAssertEqual(MeshBoolean.Operation.parse(" overlap "), .intersect)
        XCTAssertNil(MeshBoolean.Operation.parse("teleport"))
    }
}
