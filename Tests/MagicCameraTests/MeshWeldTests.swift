import XCTest
import simd
@testable import MagicCamera

/// Vertex welding and its effect on the connectivity-based editing tools.
/// Textured saves and USDZ imports carry per-corner duplicated vertices
/// ("triangle soup"); without welding, smoothing contracts every triangle
/// toward its own centroid (cracks along all edges) and hole filling sees
/// every edge as a boundary.
final class MeshWeldTests: XCTestCase {

    /// Duplicates every corner — the layout TextureAtlas.buildGeometry emits.
    private func soup(from mesh: MeshData) -> MeshData {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in mesh.indices {
            indices.append(UInt32(vertices.count))
            vertices.append(mesh.vertices[Int(i)])
            normals.append(SIMD3<Float>(0, 1, 0))
        }
        return MeshData(vertices: vertices, normals: normals, indices: indices)
    }

    private func quad() -> MeshData {
        MeshData(vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1)],
                 normals: [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: 4),
                 indices: [0, 1, 2, 0, 2, 3])
    }

    private func tetrahedron() -> MeshData {
        MeshData(vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0.5, 0, 1), SIMD3(0.5, 1, 0.5)],
                 normals: [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: 4),
                 indices: [0, 2, 1,  0, 1, 3,  1, 2, 3,  2, 0, 3])
    }

    func testWeldMergesDuplicatedCorners() {
        let welded = soup(from: quad()).weldingDuplicateVertices()
        XCTAssertEqual(welded.count, 4)
        XCTAssertEqual(welded.triangleCount, 2)
    }

    func testWeldIsIdentityOnIndexedMesh() {
        let mesh = quad()
        let welded = mesh.weldingDuplicateVertices()
        XCTAssertEqual(welded.count, mesh.count)
        XCTAssertEqual(welded.indices, mesh.indices)
    }

    func testSmoothingSoupDoesNotCrackSharedEdges() {
        // Two triangles sharing the (0,0,0)–(1,0,1) diagonal, duplicated per
        // corner. Without welding, smoothing pulls each triangle toward its own
        // centroid and the two copies of every shared corner drift apart.
        let smoothed = MeshOptimizer.smooth(soup(from: quad()), iterations: 3)
        // After the weld inside `smooth`, the surface stays one connected quad.
        XCTAssertEqual(smoothed.count, 4)
        XCTAssertEqual(smoothed.triangleCount, 2)
    }

    func testHoleFillerDoesNotDoubleSoupSurface() {
        // A closed tetrahedron exploded into soup: every edge looks like a
        // boundary until welding, and "filling" would re-add every face.
        let filled = MeshHoleFiller.fill(soup(from: tetrahedron()))
        XCTAssertEqual(filled.triangleCount, 4)
    }

    func testWeldDropsDegenerateTriangles() {
        // Two corners of the second triangle collapse onto the same position —
        // after welding it has two identical indices and must be dropped.
        let mesh = MeshData(vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1),
                                       SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)],
                            normals: [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: 6),
                            indices: [0, 1, 2, 3, 4, 5])
        let welded = mesh.weldingDuplicateVertices()
        XCTAssertEqual(welded.triangleCount, 1)
    }
}
