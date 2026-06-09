import XCTest
import simd
@testable import MagicCamera

final class PointCloudExporterTests: XCTestCase {
    private func sampleCloud(_ n: Int) -> PointCloud {
        var cloud = PointCloud()
        for i in 0..<n {
            cloud.append(position: SIMD3<Float>(Float(i), 0, 0),
                         color: SIMD3<Float>(1, 0.5, 0), confidence: 1)
        }
        return cloud
    }

    func testEmptyCloudThrows() {
        XCTAssertThrowsError(try PointCloudExporter.data(from: PointCloud(), format: .plyASCII))
    }

    func testPLYASCIIHeaderAndRows() throws {
        let data = try PointCloudExporter.data(from: sampleCloud(3), format: .plyASCII)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("ply"))
        XCTAssertTrue(text.contains("element vertex 3"))
        XCTAssertTrue(text.contains("format ascii 1.0"))
        // 3 vertex lines after the header.
        let bodyLines = text.components(separatedBy: "end_header\n").last?
            .split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(bodyLines?.count, 3)
    }

    func testPLYBinarySize() throws {
        let count = 10
        let data = try PointCloudExporter.data(from: sampleCloud(count), format: .plyBinary)
        // Header is ASCII; body is 15 bytes/point (3 float + 3 uchar).
        guard let headerRange = data.range(of: Data("end_header\n".utf8)) else {
            return XCTFail("missing end_header")
        }
        let bodyBytes = data.count - headerRange.upperBound
        XCTAssertEqual(bodyBytes, count * 15)
    }

    func testOBJVertexCount() throws {
        let data = try PointCloudExporter.data(from: sampleCloud(5), format: .obj)
        let text = String(decoding: data, as: UTF8.self)
        let vLines = text.split(separator: "\n").filter { $0.hasPrefix("v ") }
        XCTAssertEqual(vLines.count, 5)
    }

    func testPLYASCIIIncludesNormalsWhenProvided() throws {
        let cloud = sampleCloud(3)
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 3)
        let data = try PointCloudExporter.data(from: cloud, format: .plyASCII, normals: normals)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("property float nx"))
        XCTAssertTrue(text.contains("property float ny"))
        XCTAssertTrue(text.contains("property float nz"))
        // Each vertex row now carries x y z nx ny nz r g b = 9 columns.
        let firstRow = text.components(separatedBy: "end_header\n").last?
            .split(separator: "\n").first
        XCTAssertEqual(firstRow?.split(separator: " ").count, 9)
    }

    func testPLYBinaryNormalsStride() throws {
        let count = 10
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: count)
        let data = try PointCloudExporter.data(from: sampleCloud(count), format: .plyBinary, normals: normals)
        guard let headerRange = data.range(of: Data("end_header\n".utf8)) else {
            return XCTFail("missing end_header")
        }
        let bodyBytes = data.count - headerRange.upperBound
        // 6 floats (pos + normal) + 3 uchar = 27 bytes/point.
        XCTAssertEqual(bodyBytes, count * 27)
    }

    func testPLYIgnoresNormalsWithMismatchedCount() throws {
        let data = try PointCloudExporter.data(from: sampleCloud(3), format: .plyASCII,
                                               normals: [SIMD3<Float>(0, 0, 1)])  // wrong count
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("property float nx"))
    }
}
