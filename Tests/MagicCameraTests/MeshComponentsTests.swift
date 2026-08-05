//
//  MeshComponentsTests.swift
//  MagicCameraTests
//
//  Connectivity is what carries object identity through the scan pipeline, so
//  these cover the two things that must hold for a multi-object scan to survive:
//  a soup mesh reports REAL connectivity (not one component per triangle), and
//  splitting never loses geometry.
//

import XCTest
import Foundation
import simd
@testable import MagicCamera

final class MeshComponentsTests: XCTestCase {

    /// A `side`×`side` quad grid at `origin`, welded (shared corners).
    private func grid(side: Int, cell: Float, origin: SIMD3<Float>) -> MeshData {
        var mesh = MeshData()
        for z in 0...side {
            for x in 0...side {
                mesh.vertices.append(origin + SIMD3(Float(x) * cell, 0, Float(z) * cell))
                mesh.normals.append(SIMD3(0, 1, 0))
            }
        }
        let stride = UInt32(side + 1)
        for z in 0..<side {
            for x in 0..<side {
                let a = UInt32(z) * stride + UInt32(x)
                let b = a + 1, c = a + stride, d = c + 1
                mesh.indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return mesh
    }

    /// The same mesh with every corner duplicated — what a texture bake and a
    /// USDZ round-trip produce, and what naive connectivity reads as thousands
    /// of isolated triangles.
    private func soup(_ mesh: MeshData) -> MeshData {
        var out = MeshData()
        var t = 0
        while t + 2 < mesh.indices.count {
            for k in 0..<3 {
                let v = Int(mesh.indices[t + k])
                out.vertices.append(mesh.vertices[v])
                if mesh.normals.count == mesh.vertices.count {
                    out.normals.append(mesh.normals[v])
                }
                out.indices.append(UInt32(out.vertices.count - 1))
            }
            t += 3
        }
        return out
    }

    func testASingleSurfaceIsOneComponent() {
        let (labels, sizes) = grid(side: 6, cell: 0.1, origin: .zero).triangleComponents()
        XCTAssertEqual(sizes.count, 1)
        XCTAssertTrue(labels.allSatisfy { $0 == 0 })
    }

    func testTwoSeparatedSurfacesAreTwoComponents() {
        let two = grid(side: 6, cell: 0.1, origin: .zero)
            .appending(grid(side: 6, cell: 0.1, origin: SIMD3(5, 0, 0)))
        let (_, sizes) = two.triangleComponents()
        XCTAssertEqual(sizes.count, 2)
        XCTAssertEqual(sizes[0], sizes[1], "the two halves are the same size")
    }

    /// The rule that makes the whole thing work on real data: baked meshes are
    /// duplicated-corner soup, and connectivity must be read on welded positions.
    func testSoupMeshReportsRealConnectivity() {
        let two = grid(side: 6, cell: 0.1, origin: .zero)
            .appending(grid(side: 6, cell: 0.1, origin: SIMD3(5, 0, 0)))
        let (_, sizes) = soup(two).triangleComponents()
        XCTAssertEqual(sizes.count, 2, "soup must not read as one component per triangle")
    }

    func testSeparatesTwoObjectsKeepingEveryTriangle() {
        let two = grid(side: 6, cell: 0.1, origin: .zero)
            .appending(grid(side: 6, cell: 0.1, origin: SIMD3(5, 0, 0)))
        let parts = two.separatedComponents()
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.triangleCount }, two.triangleCount,
                       "splitting must not lose a triangle")
        // Each part is a compact mesh, not the original with holes.
        for part in parts { XCTAssertEqual(part.vertices.count, 49) }
    }

    /// A room with a few reconstruction specks is ONE object, not thirty — but
    /// the specks are still in it.
    func testSpecksFoldIntoTheMainBodyRatherThanBecomingObjects() {
        var mesh = grid(side: 16, cell: 0.1, origin: .zero)
        let bodyTris = mesh.triangleCount
        for i in 0..<5 {
            mesh = mesh.appending(grid(side: 1, cell: 0.01,
                                       origin: SIMD3(Float(i) * 3 + 20, 0, 0)))
        }
        let parts = mesh.separatedComponents()
        XCTAssertEqual(parts.count, 1, "specks are not objects")
        XCTAssertEqual(parts[0].triangleCount, mesh.triangleCount,
                       "…but they are not deleted either")
        XCTAssertGreaterThan(mesh.triangleCount, bodyTris)
    }

    func testASingleObjectStaysOneSlice() {
        let slices = grid(side: 6, cell: 0.1, origin: .zero).componentSlices()
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].mesh.triangleCount, 72)
    }

    /// The texture must follow the split, or a separated scan loses its photos.
    func testTexturedSplitCarriesUVsAndPages() {
        let two = grid(side: 4, cell: 0.1, origin: .zero)
            .appending(grid(side: 4, cell: 0.1, origin: SIMD3(5, 0, 0)))
        let uvs = (0..<two.vertices.count).map {
            SIMD2<Float>(Float($0) / Float(two.vertices.count), 0.5)
        }
        // Two pages, split down the middle by triangle index.
        let pages = (0..<two.triangleCount).map { UInt8($0 < two.triangleCount / 2 ? 0 : 1) }
        let textured = TexturedMesh(mesh: two, uvs: uvs,
                                    textures: [Data([1]), Data([2])],
                                    textureSize: 64, pageOfTri: pages)
        let parts = textured.separatedComponents()
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            XCTAssertEqual(part.uvs.count, part.mesh.vertices.count,
                           "UVs must stay index-aligned to the part's vertices")
            XCTAssertEqual(part.pageOfTri.count, part.mesh.triangleCount)
            XCTAssertEqual(part.textures.count, 2, "every page rides along")
        }
        XCTAssertEqual(parts.reduce(0) { $0 + $1.mesh.triangleCount }, two.triangleCount)
    }

    func testEmptyMeshSeparatesIntoNothing() {
        XCTAssertTrue(MeshData().componentSlices().isEmpty)
    }
}

final class MultiSubjectIsolationTests: XCTestCase {

    /// A solid block of points centred at `center`.
    private func blob(at center: SIMD3<Float>, side: Int = 8, spacing: Float = 0.015)
        -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let half = Float(side - 1) * spacing * 0.5
        for z in 0..<side { for y in 0..<side { for x in 0..<side {
            out.append(center + SIMD3(Float(x) * spacing - half,
                                      Float(y) * spacing - half,
                                      Float(z) * spacing - half))
        } } }
        return out
    }

    private func cloud(_ groups: [[SIMD3<Float>]]) -> PointCloud {
        var c = PointCloud()
        for group in groups {
            for p in group {
                c.append(position: p, color: SIMD3(repeating: 0.5), confidence: 1)
            }
        }
        return c
    }

    /// Two subjects side by side, far enough apart that neither absorbs the other.
    private let leftCenter = SIMD3<Float>(0, 0, 0)
    private let rightCenter = SIMD3<Float>(0.6, 0, 0)

    func testOneAnchorKeepsOneSubject() throws {
        let scene = cloud([blob(at: leftCenter), blob(at: rightCenter)])
        let result = try XCTUnwrap(
            PointCloudSegmenter.isolateSubjects(scene, anchors: [leftCenter]))
        XCTAssertEqual(result.subjectCount, 1)
        // Everything kept is on the left — the point of trusting the tap.
        for p in result.cloud.positions {
            XCTAssertLessThan(p.x, 0.3, "the untapped subject must not be kept")
        }
    }

    /// The complaint, as a test: pointing at both objects keeps both.
    func testTwoAnchorsKeepBothSubjects() throws {
        let scene = cloud([blob(at: leftCenter), blob(at: rightCenter)])
        let one = try XCTUnwrap(
            PointCloudSegmenter.isolateSubjects(scene, anchors: [leftCenter]))
        let both = try XCTUnwrap(
            PointCloudSegmenter.isolateSubjects(scene, anchors: [leftCenter, rightCenter]))
        XCTAssertEqual(both.subjectCount, 2)
        XCTAssertGreaterThan(both.keptPoints, one.keptPoints * 3 / 2,
                             "the second subject must actually be in there")
        XCTAssertTrue(both.cloud.positions.contains { $0.x > 0.3 },
                      "points from the right-hand subject are kept")
        XCTAssertTrue(both.cloud.positions.contains { $0.x < 0.3 },
                      "…and the left-hand one is still there too")
    }

    /// Two taps on the same object are one object, not two.
    func testAnchorsOnTheSameObjectCollapse() throws {
        let scene = cloud([blob(at: leftCenter), blob(at: rightCenter)])
        let result = try XCTUnwrap(PointCloudSegmenter.isolateSubjects(
            scene, anchors: [leftCenter, leftCenter + SIMD3(0.01, 0.01, 0)]))
        XCTAssertEqual(result.subjectCount, 1)
    }

    /// No point is kept twice when subjects are picked one after another.
    func testSubjectsDoNotOverlap() throws {
        let scene = cloud([blob(at: leftCenter), blob(at: rightCenter)])
        let both = try XCTUnwrap(
            PointCloudSegmenter.isolateSubjects(scene, anchors: [leftCenter, rightCenter]))
        var seen = Set<SIMD3<Float>>()
        for p in both.cloud.positions {
            XCTAssertTrue(seen.insert(p).inserted, "a point was kept twice")
        }
    }

    /// The device failure this rule exists for: a mug with a lamp in it, tapped
    /// on the small thing facing the camera.
    ///
    /// The tap lands on a feature that clusters separately from the body below
    /// it. Seeding there used to be fatal — the growth rule refuses anything
    /// LARGER than its seed, so the body could never join, and a 321 k point
    /// scan reconstructed as the top 4.6 cm of itself (2.5 % of the cloud,
    /// visibly squashed flat). The seed must walk up to the body first.
    func testTappingASmallFeatureStillKeepsTheBodyUnderIt() throws {
        // The device scan's own shape: a broad table, a hollow body standing on
        // it, and a small feature above the body. A SHELL, not a solid block —
        // scanned objects are surfaces, and a solid block has a dominant plane
        // through its own middle, which is a property no real scan has.
        var table: [SIMD3<Float>] = []
        for z in 0..<60 { for x in 0..<60 {
            table.append(SIMD3(Float(x) * 0.01 - 0.24, 0, Float(z) * 0.01 - 0.24))
        } }
        var body: [SIMD3<Float>] = []          // open-topped box, 12 cm tall
        for y in 0..<20 { for k in 0..<14 {
            let h = 0.012 + Float(y) * 0.006
            let t = Float(k) * 0.008
            body.append(SIMD3(t, h, 0))
            body.append(SIMD3(t, h, 0.104))
            body.append(SIMD3(0, h, t))
            body.append(SIMD3(0.104, h, t))
        } }
        // A small feature 5 cm above the body's rim, on the same wall line so the
        // SURFACE gap is unambiguously 5 cm. Far enough that the 3x-spacing
        // cluster lattice separates them (it merges anything within ~2 cells),
        // close enough to read as one object with a hole in the scan.
        var cap: [SIMD3<Float>] = []
        for k in 0..<6 { for j in 0..<6 {
            cap.append(SIMD3(0.03 + Float(k) * 0.006, 0.176 + Float(j) * 0.004, 0))
        } }
        XCTAssertGreaterThan(body.count, cap.count * 5, "the body is much bigger")

        let scene = cloud([table, body, cap])
        // The tap lands on the small feature, which is what a user aiming at the
        // thing facing them actually hits.
        let result = try XCTUnwrap(PointCloudSegmenter.isolateSubjects(
            scene, anchors: [SIMD3(0.048, 0.186, 0)]))
        // The body has to be in there — that is the whole point.
        XCTAssertGreaterThan(result.keptPoints, body.count / 2,
                             "tapping the cap must not throw the body away")
        XCTAssertTrue(result.cloud.positions.contains { $0.y < 0.06 },
                      "the bottom of the body survives")
    }

    /// The historical entry point still means what it meant.
    func testSingleSubjectEntryPointIsUnchanged() throws {
        let scene = cloud([blob(at: leftCenter), blob(at: rightCenter)])
        let viaMain = try XCTUnwrap(
            PointCloudSegmenter.isolateMainSubject(scene, anchor: leftCenter))
        let viaSubjects = try XCTUnwrap(
            PointCloudSegmenter.isolateSubjects(scene, anchors: [leftCenter]))
        XCTAssertEqual(viaMain.keptPoints, viaSubjects.keptPoints)
    }
}
