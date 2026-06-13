import XCTest
import simd
@testable import MagicCamera

/// Model Studio's primitive generator and the stage baker. The signed-volume
/// checks double as winding tests: a closed mesh with consistent CCW-outward
/// triangles has a positive signed volume close to the analytic one; flipped
/// or mixed winding would show up as a negative or collapsed value.
final class StudioPrimitiveTests: XCTestCase {

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

    private func assertWellFormed(_ mesh: MeshData, _ label: String) {
        XCTAssertFalse(mesh.isEmpty, "\(label) is empty")
        XCTAssertEqual(mesh.normals.count, mesh.vertices.count, "\(label) normals mismatch")
        XCTAssertEqual(mesh.indices.count % 3, 0, "\(label) has dangling indices")
        XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.vertices.count },
                      "\(label) has out-of-range indices")
        for normal in mesh.normals {
            XCTAssertEqual(simd_length(normal), 1, accuracy: 0.01, "\(label) has unnormalised normals")
        }
    }

    /// All primitives sit on y = 0, centred in X/Z, with the requested bounds.
    func testPrimitivesMatchRequestedBounds() {
        let size = SIMD3<Float>(0.4, 0.3, 0.2)
        for shape in PrimitiveShape.allCases {
            let mesh = PrimitiveMesher.mesh(shape, size: size)
            assertWellFormed(mesh, shape.rawValue)
            guard let box = mesh.boundingBox() else {
                return XCTFail("\(shape.rawValue) has no bounds")
            }
            XCTAssertEqual(box.min.y, 0, accuracy: 1e-4, "\(shape.rawValue) base off the ground")
            XCTAssertEqual(box.max.x, -box.min.x, accuracy: 1e-3, "\(shape.rawValue) not centred in x")
            XCTAssertEqual(box.max.z, -box.min.z, accuracy: 1e-3, "\(shape.rawValue) not centred in z")
            XCTAssertEqual(box.max.x - box.min.x, size.x, accuracy: 0.01)
            XCTAssertEqual(box.max.z - box.min.z, size.z, accuracy: 0.01)
            switch shape {
            case .plane:
                break                           // flat by definition
            case .torus:
                // Tube radius is capped by the footprint, so the height is
                // 2 · min(size.y / 2, min(size.x, size.z) / 4).
                let tube = min(size.y / 2, min(size.x, size.z) / 4)
                XCTAssertEqual(box.max.y, tube * 2, accuracy: 0.01)
            default:
                XCTAssertEqual(box.max.y, size.y, accuracy: 0.01)
            }
        }
    }

    func testClosedPrimitivesHaveAnalyticVolume() {
        let cases: [(PrimitiveShape, SIMD3<Float>, Float)] = [
            (.box, SIMD3(0.4, 0.3, 0.2), 0.4 * 0.3 * 0.2),
            (.sphere, SIMD3(0.4, 0.3, 0.2), 4 / 3 * .pi * 0.2 * 0.15 * 0.1),
            (.cylinder, SIMD3(0.4, 0.3, 0.2), .pi * 0.2 * 0.1 * 0.3),
            (.cone, SIMD3(0.4, 0.3, 0.2), .pi * 0.2 * 0.1 * 0.3 / 3),
            // Circular torus: V = 2π² · R · r² with r = h/2, R = w/2 − r.
            (.torus, SIMD3(0.4, 0.1, 0.4), 2 * .pi * .pi * 0.15 * 0.05 * 0.05),
        ]
        for (shape, size, expected) in cases {
            let volume = signedVolume(PrimitiveMesher.mesh(shape, size: size))
            XCTAssertGreaterThan(volume, 0, "\(shape.rawValue) wound inward")
            XCTAssertEqual(volume, expected, accuracy: expected * 0.08,
                           "\(shape.rawValue) volume off")
        }
    }

    func testShapeParsingAcceptsSynonyms() {
        XCTAssertEqual(PrimitiveShape.parse("Cube"), .box)
        XCTAssertEqual(PrimitiveShape.parse(" ball "), .sphere)
        XCTAssertEqual(PrimitiveShape.parse("donut"), .torus)
        XCTAssertEqual(PrimitiveShape.parse("pillar"), .cylinder)
        XCTAssertNil(PrimitiveShape.parse("dodecahedron"))
    }

    func testPaletteLookupIsLenientAboutSpelling() {
        XCTAssertEqual(StudioPalette.color(named: "Grey")?.name, "gray")
        XCTAssertEqual(StudioPalette.color(named: "violet")?.name, "purple")
        XCTAssertNotNil(StudioPalette.color(named: "RED"))
        XCTAssertNil(StudioPalette.color(named: "chartreuse"))
    }

    // MARK: - Stage baker

    func testBakerPreservesGeometryAndColours() throws {
        let red = StudioObject(name: "A",
                               mesh: PrimitiveMesher.mesh(.box, size: SIMD3(0.2, 0.2, 0.2)),
                               color: SIMD3(0.9, 0.2, 0.2), colorName: "red", revision: 0)
        let blue = StudioObject(name: "B",
                                mesh: PrimitiveMesher.mesh(.sphere, size: SIMD3(0.2, 0.2, 0.2)),
                                color: SIMD3(0.2, 0.2, 0.9), colorName: "blue", revision: 0)
        let merged = ModelStudioBaker.merge([red, blue])
        XCTAssertEqual(merged.vertices.count,
                       red.mesh.vertices.count + blue.mesh.vertices.count)
        XCTAssertEqual(merged.triangleCount,
                       red.mesh.triangleCount + blue.mesh.triangleCount)

        let textured = try XCTUnwrap(ModelStudioBaker.bakePalette([red, blue], merged: merged))
        XCTAssertEqual(textured.uvs.count, merged.vertices.count)
        XCTAssertFalse(textured.texturePNG.isEmpty)
        // The two objects must land on different palette stripes, every vertex
        // of one object on the same stripe.
        let redUs = Set(textured.uvs.prefix(red.mesh.vertices.count).map(\.x))
        let blueUs = Set(textured.uvs.suffix(blue.mesh.vertices.count).map(\.x))
        XCTAssertEqual(redUs.count, 1)
        XCTAssertEqual(blueUs.count, 1)
        XCTAssertNotEqual(redUs, blueUs)
    }
}
