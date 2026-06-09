//
//  MeshGLBExporterTests.swift
//  MagicCameraTests
//
//  Verifies the binary glTF 2.0 (.glb) serialisation: container header, JSON
//  chunk structure, and that normals are optional.
//
import XCTest
import simd
@testable import MagicCamera

final class MeshGLBExporterTests: XCTestCase {

    private func quadMesh() -> MeshData {
        let v = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                 SIMD3<Float>(1, 1, 0), SIMD3<Float>(0, 1, 0)]
        let n = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 4)
        let idx: [UInt32] = [0, 1, 2, 0, 2, 3]
        return MeshData(vertices: v, normals: n, indices: idx)
    }

    private func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        let b = Array(data[offset..<offset + 4])
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private func jsonChunk(of data: Data) -> [String: Any]? {
        guard data.count > 20 else { return nil }
        let len = Int(readUInt32LE(data, 12))
        let start = 20, end = 20 + len
        guard end <= data.count else { return nil }
        return (try? JSONSerialization.jsonObject(with: data.subdata(in: start..<end))) as? [String: Any]
    }

    func testGLBHeaderIsValid() throws {
        let data = try MeshGLBExporter.data(from: quadMesh())
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "glTF")
        XCTAssertEqual(readUInt32LE(data, 4), 2)                 // glTF version
        XCTAssertEqual(Int(readUInt32LE(data, 8)), data.count)   // total length
        XCTAssertEqual(data.count % 4, 0)                        // 4-byte aligned
    }

    func testGLBJSONDescribesMesh() throws {
        let data = try MeshGLBExporter.data(from: quadMesh())
        let json = try XCTUnwrap(jsonChunk(of: data))
        XCTAssertEqual((json["asset"] as? [String: Any])?["version"] as? String, "2.0")

        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        XCTAssertEqual(accessors.count, 3)   // indices, position, normal
        let position = accessors[1]
        XCTAssertEqual(position["count"] as? Int, 4)
        XCTAssertNotNil(position["min"])
        XCTAssertNotNil(position["max"])

        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let primitive = try XCTUnwrap((meshes[0]["primitives"] as? [[String: Any]])?.first)
        let attributes = try XCTUnwrap(primitive["attributes"] as? [String: Any])
        XCTAssertNotNil(attributes["POSITION"])
        XCTAssertNotNil(attributes["NORMAL"])
        XCTAssertEqual(primitive["mode"] as? Int, 4)   // TRIANGLES
        XCTAssertNotNil(json["materials"])
    }

    func testGLBWithoutNormalsOmitsNormalAttribute() throws {
        var mesh = quadMesh()
        mesh.normals = []
        let data = try MeshGLBExporter.data(from: mesh)
        let json = try XCTUnwrap(jsonChunk(of: data))
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        XCTAssertEqual(accessors.count, 2)   // indices + position only
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let primitive = (meshes[0]["primitives"] as? [[String: Any]])?.first
        let attributes = primitive?["attributes"] as? [String: Any]
        XCTAssertNil(attributes?["NORMAL"])
    }

    func testEmptyMeshThrows() {
        XCTAssertThrowsError(try MeshGLBExporter.data(from: MeshData()))
    }
}
