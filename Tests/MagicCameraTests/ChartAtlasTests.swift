//
//  ChartAtlasTests.swift
//  MagicCameraTests
//
//  The UV unwrap's contract: contiguous charts (shared mesh edges get
//  numerically identical UVs — the seamlessness), planar regions collapse into
//  few charts, distinct orientations split, texel density is uniform across
//  charts, and every chart stays inside the atlas without overlapping another.
//

import XCTest
import simd
@testable import MagicCamera

final class ChartAtlasTests: XCTestCase {

    /// Indexed grid plane in the XZ plane (normal +Y), `side`×`side` quads.
    private static func planeMesh(side: Int, spacing: Float,
                                  origin: SIMD3<Float> = .zero) -> MeshData {
        var mesh = MeshData()
        for z in 0...side {
            for x in 0...side {
                mesh.vertices.append(origin + SIMD3(Float(x) * spacing, 0, Float(z) * spacing))
                mesh.normals.append(SIMD3(0, 1, 0))
            }
        }
        let row = side + 1
        for z in 0..<side {
            for x in 0..<side {
                let a = UInt32(z * row + x), b = a + 1
                let c = UInt32((z + 1) * row + x), d = c + 1
                mesh.indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return mesh
    }

    func testPlaneUnwrapsToOneSeamlessChart() throws {
        let mesh = Self.planeMesh(side: 6, spacing: 0.1)
        let layout = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 1024,
                                                    minTexSize: 256))
        XCTAssertEqual(layout.chartCount, 1)

        // Seamlessness: every shared 3-D vertex maps to ONE pixel coordinate.
        var uvByVertex: [Int: SIMD2<Float>] = [:]
        let triCount = mesh.indices.count / 3
        for t in 0..<triCount {
            let corners = layout.corners(of: t)
            for (k, uv) in [corners.0, corners.1, corners.2].enumerated() {
                let vertex = Int(mesh.indices[t * 3 + k])
                if let existing = uvByVertex[vertex] {
                    XCTAssertEqual(existing.x, uv.x, accuracy: 1e-3)
                    XCTAssertEqual(existing.y, uv.y, accuracy: 1e-3)
                } else {
                    uvByVertex[vertex] = uv
                }
                XCTAssertGreaterThanOrEqual(uv.x, 0)
                XCTAssertGreaterThanOrEqual(uv.y, 0)
                XCTAssertLessThan(uv.x, Float(layout.texSize))
                XCTAssertLessThan(uv.y, Float(layout.texSize))
            }
        }
    }

    func testWeldsDuplicatedCornerSoup() throws {
        // The same plane as triangle soup (duplicated corners) must weld back
        // into one chart with shared UVs — saved/reloaded meshes arrive as soup.
        let indexed = Self.planeMesh(side: 4, spacing: 0.1)
        var soup = MeshData()
        for i in indexed.indices {
            soup.vertices.append(indexed.vertices[Int(i)])
            soup.normals.append(indexed.normals[Int(i)])
            soup.indices.append(UInt32(soup.vertices.count - 1))
        }
        let layout = try XCTUnwrap(ChartAtlas.build(mesh: soup, maxTexSize: 1024,
                                                    minTexSize: 256))
        XCTAssertEqual(layout.chartCount, 1)
    }

    func testPerpendicularWallsSplitIntoSeparateNonOverlappingCharts() throws {
        // Floor (+Y) and a wall (+Z) sharing an edge: the 90° normal jump must
        // split them, and the packed charts must not overlap in the atlas.
        var mesh = Self.planeMesh(side: 3, spacing: 0.1)
        let base = UInt32(mesh.vertices.count)
        for y in 0...3 {
            for x in 0...3 {
                mesh.vertices.append(SIMD3(Float(x) * 0.1, Float(y) * 0.1, 0))
                mesh.normals.append(SIMD3(0, 0, 1))
            }
        }
        for y in 0..<3 {
            for x in 0..<3 {
                let a = base + UInt32(y * 4 + x), b = a + 1
                let c = base + UInt32((y + 1) * 4 + x), d = c + 1
                mesh.indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        let layout = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 1024,
                                                    minTexSize: 256))
        XCTAssertEqual(layout.chartCount, 2)

        // No triangle of one chart may rasterise into another chart's texels:
        // paint each triangle's texels with its chart id (floor tris first —
        // chart split means the two groups must claim disjoint texels).
        let triCount = mesh.indices.count / 3
        let floorTris = 3 * 3 * 2
        var owner = [Int8](repeating: -1, count: layout.texSize * layout.texSize)
        for t in 0..<triCount {
            let group: Int8 = t < floorTris ? 0 : 1
            TextureAtlas.forEachTexel(corners: layout.corners(of: t),
                                      texSize: layout.texSize) { px, py, _, _, _ in
                let i = py * layout.texSize + px
                XCTAssertTrue(owner[i] == -1 || owner[i] == group,
                              "texel (\(px),\(py)) claimed by both charts")
                owner[i] = group
            }
        }
    }

    func testTexelDensityIsUniformAcrossChartSizes() throws {
        // A big floor and a small far-away plate: pixels-per-metre must match
        // (the per-triangle grid starved big triangles — the whole point here).
        var mesh = Self.planeMesh(side: 6, spacing: 0.2)              // 1.44 m²
        let plate = Self.planeMesh(side: 2, spacing: 0.05,
                                   origin: SIMD3(5, 5, 5))            // 0.01 m²
        let base = UInt32(mesh.vertices.count)
        mesh.vertices.append(contentsOf: plate.vertices)
        mesh.normals.append(contentsOf: plate.normals)
        mesh.indices.append(contentsOf: plate.indices.map { $0 + base })
        let layout = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 2048,
                                                    minTexSize: 256))
        XCTAssertEqual(layout.chartCount, 2)

        func pixelPerMetre(triangle t: Int) -> Float {
            let (a, b, c) = layout.corners(of: t)
            let pixelArea = abs((b - a).x * (c - a).y - (c - a).x * (b - a).y) / 2
            let i0 = Int(mesh.indices[t * 3]), i1 = Int(mesh.indices[t * 3 + 1])
            let i2 = Int(mesh.indices[t * 3 + 2])
            let worldArea = simd_length(simd_cross(mesh.vertices[i1] - mesh.vertices[i0],
                                                   mesh.vertices[i2] - mesh.vertices[i0])) / 2
            return (pixelArea / worldArea).squareRoot()
        }
        let floorDensity = pixelPerMetre(triangle: 0)
        let plateDensity = pixelPerMetre(triangle: mesh.indices.count / 3 - 1)
        XCTAssertEqual(floorDensity / plateDensity, 1, accuracy: 0.05)
    }

    // MARK: - Gate search
    //
    // These cover the SEARCH's control flow only — that it skips when the atlas
    // isn't area-limited, that a tie keeps the tightest gate, that the winner
    // comes from the candidate set.
    //
    // There is deliberately NO test here that a loose gate wins on a scan. The
    // shatter it exists to undo is ORPHANING: a face the gate rejects finds its
    // neighbours already claimed and seeds a 1-2 triangle island of its own, and
    // that needs the scattered normal noise a marching-cubes surface actually
    // has. Regular synthetic relief does not reproduce it — a ±25° zigzag grid
    // yields 12 clean strips that pack fine at ANY gate, so the search correctly
    // ties back to 0.75 and an "it loosens" assertion fails on a working
    // implementation. Loosening is measured instead on real exported device
    // meshes (scratchpad chart harness, double-sided soup deduped first):
    //
    //   object 0.11 m²   gate 0.75   no-op          (density already at target)
    //   room 26.7 m²     gate 0.25   1.30 → 0.99 mm/texel
    //   room 118 m²      gate 0.10   2.77 → 2.29 mm/texel
    //   room 142.6 m²    gate 0.50   3.05 → 2.71 mm/texel
    //
    // Same trap as the r54 slat detector, which passed on a smooth analytic wall
    // and then read the MC lattice itself as a 120-slat blind on device: validate
    // geometry heuristics against real meshes, not hand-made ones.

    func testGateStaysTightWhenAtlasIsNotAreaLimited() throws {
        // Object scale: the atlas already affords the target density, so bigger
        // charts cannot buy any and the search must not trade distortion for
        // nothing — it should not even run.
        let mesh = Self.planeMesh(side: 4, spacing: 0.1)          // 0.16 m²
        let layout = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 4096,
                                                    minTexSize: 256))
        XCTAssertEqual(layout.gate, 0.75)
    }

    func testGateComesFromTheCandidateSet() throws {
        let mesh = Self.planeMesh(side: 8, spacing: 0.1)
        let layout = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 1024,
                                                    minTexSize: 256))
        XCTAssertTrue([0.75, 0.5, 0.25, 0.1].contains(layout.gate),
                      "gate \(layout.gate) is not a candidate")
    }

    func testTieOnAFlatPlaneKeepsTheTightestGate() throws {
        // Area-limited (so the search runs), but every face shares one normal —
        // each gate yields the identical layout, and the tightest must win.
        let mesh = Self.planeMesh(side: 8, spacing: 0.1)          // 0.64 m²
        let layout = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 1024,
                                                    minTexSize: 256))
        XCTAssertEqual(layout.chartCount, 1)
        XCTAssertEqual(layout.gate, 0.75)
    }

    func testDegenerateInputReturnsNil() {
        XCTAssertNil(ChartAtlas.build(mesh: MeshData(), maxTexSize: 1024))
        var line = MeshData()
        line.vertices = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)]
        line.indices = [0, 1, 2]   // zero-area triangle
        XCTAssertNil(ChartAtlas.build(mesh: line, maxTexSize: 1024))
    }
}
