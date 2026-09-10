//
//  MeshPageGeometryTests.swift
//  Magic Camera
//
//  The page split feeding the RealityKit renderer. The renderer itself needs a
//  device; this does not, and it is where the off-by-one lives — a triangle put on
//  the wrong page samples the wrong 8192² sheet, which is the exact failure the
//  multi-page atlas has produced twice before under different names.
//

import XCTest
import simd
@testable import MagicCamera

final class MeshPageGeometryTests: XCTestCase {

    /// `count` disjoint triangles, one vertex trio each.
    private func triangles(_ count: Int) -> (MeshData, [SIMD2<Float>]) {
        var mesh = MeshData()
        var uvs: [SIMD2<Float>] = []
        for t in 0..<count {
            let x = Float(t)
            for corner in 0..<3 {
                mesh.vertices.append(SIMD3(x + Float(corner), 0, 0))
                mesh.normals.append(SIMD3(0, 1, 0))
                uvs.append(SIMD2(Float(corner) / 2, x / Float(max(count, 1))))
                mesh.indices.append(UInt32(t * 3 + corner))
            }
        }
        return (mesh, uvs)
    }

    func testUnpagedMeshComesBackAsOnePage() {
        let (mesh, uvs) = triangles(4)
        let pages = MeshPageGeometry.pages(mesh: mesh, uvs: uvs)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].indices.count, 12)
        XCTAssertEqual(pages[0].positions.count, 12)
        XCTAssertEqual(pages[0].textureCoordinates.count, 12)
    }

    func testEachTriangleLandsOnItsOwnPage() {
        let (mesh, uvs) = triangles(6)
        let pageOfTri: [UInt8] = [0, 1, 0, 1, 2, 2]
        let pages = MeshPageGeometry.pages(mesh: mesh, uvs: uvs,
                                           pageOfTri: pageOfTri, pageCount: 3)
        XCTAssertEqual(pages.map(\.page), [0, 1, 2])
        XCTAssertEqual(pages.map { $0.indices.count / 3 }, [2, 2, 2])

        // Every page's geometry must be its OWN triangles, positioned where the
        // source put them — the check that would catch a page mix-up.
        for page in pages {
            let expected = pageOfTri.indices.filter { pageOfTri[$0] == UInt8(page.page) }
            let xs = Set(page.positions.map { $0.x })
            for t in expected {
                XCTAssertTrue(xs.contains(Float(t)), "page \(page.page) is missing triangle \(t)")
            }
        }
    }

    /// Indices must address the page's own compacted buffer, not the original.
    func testIndicesAreRemappedIntoThePagesOwnBuffer() {
        let (mesh, uvs) = triangles(4)
        let pages = MeshPageGeometry.pages(mesh: mesh, uvs: uvs,
                                           pageOfTri: [0, 1, 1, 1], pageCount: 2)
        for page in pages {
            for index in page.indices {
                XCTAssertLessThan(Int(index), page.positions.count)
            }
            XCTAssertEqual(page.normals.count, page.positions.count)
            XCTAssertEqual(page.textureCoordinates.count, page.positions.count)
        }
    }

    /// A page nothing landed on must not produce an empty draw call.
    func testEmptyPagesAreDropped() {
        let (mesh, uvs) = triangles(3)
        let pages = MeshPageGeometry.pages(mesh: mesh, uvs: uvs,
                                           pageOfTri: [0, 0, 3], pageCount: 4)
        XCTAssertEqual(pages.map(\.page), [0, 3])
    }

    func testUntexturedMeshCarriesNoTextureCoordinates() {
        let (mesh, _) = triangles(2)
        let pages = MeshPageGeometry.pages(mesh: mesh)
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].textureCoordinates.isEmpty)
        XCTAssertEqual(pages[0].normals.count, pages[0].positions.count)
    }

    func testEmptyMeshProducesNothing() {
        XCTAssertTrue(MeshPageGeometry.pages(mesh: MeshData()).isEmpty)
    }

    /// A vertex shared across pages is duplicated into each rather than making one
    /// page index into another's buffer.
    func testSharedVerticesAreDuplicatedPerPage() {
        var mesh = MeshData()
        for i in 0..<4 {
            mesh.vertices.append(SIMD3(Float(i), 0, 0))
            mesh.normals.append(SIMD3(0, 1, 0))
        }
        mesh.indices = [0, 1, 2, 1, 2, 3]           // two triangles sharing an edge
        let pages = MeshPageGeometry.pages(mesh: mesh, pageOfTri: [0, 1], pageCount: 2)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].positions.count, 3)
        XCTAssertEqual(pages[1].positions.count, 3)
    }

    /// A truncated index buffer must be trimmed to whole triangles, not passed on.
    func testPartialTrianglesAreDropped() {
        var mesh = MeshData()
        for i in 0..<3 {
            mesh.vertices.append(SIMD3(Float(i), 0, 0))
            mesh.normals.append(SIMD3(0, 1, 0))
        }
        mesh.indices = [0, 1, 2, 0, 1]              // one whole triangle, one stub
        let pages = MeshPageGeometry.pages(mesh: mesh)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].indices.count % 3, 0)
        XCTAssertEqual(pages[0].indices.count, 3)
    }
}
