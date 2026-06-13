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

    /// Autosave writes a recoverable snapshot and stays out of the project list.
    func testAutosaveSnapshotsAndRecovers() throws {
        StudioAutoSave.clear()
        addTeardownBlock { StudioAutoSave.clear() }

        // Encode straight to the autosave URL (bypassing the async queue so the
        // test is deterministic), then read it back through the loader.
        let objects = sampleObjects()
        try StageStore.encode(objects).write(to: StudioAutoSave.url, options: .atomic)

        XCTAssertNotNil(StudioAutoSave.pending())
        let loaded = try StageStore.load(StudioAutoSave.url)
        XCTAssertEqual(loaded.count, objects.count)
        // The reserved snapshot must not appear among saved projects.
        XCTAssertFalse(StageStore.list().contains { $0.url == StudioAutoSave.url })

        StudioAutoSave.clear()
    }

    /// A photo-textured object must survive the project round-trip (item 6:
    /// imported scans keep their photographs through save/reopen).
    func testTexturedObjectRoundTrip() throws {
        let mesh = PrimitiveMesher.mesh(.box, size: SIMD3(0.2, 0.2, 0.2))
        // A trivially valid atlas + per-vertex UVs.
        let size = 8
        let pixels = [UInt8](repeating: 200, count: size * size * 4)
        let png = try XCTUnwrap(TextureAtlas.encodePNG(pixels: pixels, size: size))
        let uvs = (0..<mesh.vertices.count).map { _ in SIMD2<Float>(0.5, 0.5) }
        let textured = StudioObject(
            name: "Scan", mesh: mesh,
            texture: StudioTexture(uvs: uvs, texturePNG: png, textureSize: size),
            revision: 1)

        let name = "UnitTestTextured-\(UUID().uuidString)"
        let url = try StageStore.save([textured], name: name)
        defer { StageStore.delete(url) }

        let loaded = try StageStore.load(url)
        let stored = try XCTUnwrap(loaded.first?.texture)
        XCTAssertEqual(stored.uvs.count, uvs.count)
        XCTAssertEqual(stored.textureSize, size)
        XCTAssertEqual(stored.texturePNG, png)
    }

    /// bake() must keep a photo texture (item 6) and produce one atlas whose
    /// UVs cover the merged mesh; a colour-only stage falls back to the
    /// palette path.
    func testBakeMixedStageProducesTexturedMesh() throws {
        let mesh = PrimitiveMesher.mesh(.box, size: SIMD3(0.2, 0.2, 0.2))
        let size = 8
        let png = try XCTUnwrap(TextureAtlas.encodePNG(
            pixels: [UInt8](repeating: 120, count: size * size * 4), size: size))
        let uvs = (0..<mesh.vertices.count).map { _ in SIMD2<Float>(0.5, 0.5) }
        let scan = StudioObject(
            name: "Scan", mesh: mesh,
            texture: StudioTexture(uvs: uvs, texturePNG: png, textureSize: size),
            revision: 1)
        let plain = StudioObject(name: "Box",
                                 mesh: PrimitiveMesher.mesh(.sphere, size: SIMD3(0.2, 0.2, 0.2)),
                                 color: SIMD3(0.3, 0.7, 0.4), colorName: "green", revision: 2)

        let baked = try XCTUnwrap(ModelStudioBaker.bake([scan, plain]))
        let textured = try XCTUnwrap(baked.textured)
        XCTAssertEqual(textured.uvs.count, baked.mesh.vertices.count)
        XCTAssertEqual(textured.mesh.vertices.count,
                       scan.mesh.vertices.count + plain.mesh.vertices.count)
        XCTAssertFalse(textured.texturePNG.isEmpty)
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
