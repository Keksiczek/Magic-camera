//
//  MultiPageAtlasTests.swift
//  MagicCameraTests
//
//  The multi-page atlas contract, end to end: a large surface spends pages and
//  gains √N texel density while a small one refuses to, the page map survives
//  the on-disk codec, exporters emit one material per page, and an unpaged
//  bake is bit-for-bit what it always was.
//
//  The density claims themselves are measured against REAL device exports (the
//  project's synthetic meshes have misled this area three times); what is
//  pinned here is the plumbing every one of those measurements rides on.
//

import XCTest
import simd
@testable import MagicCamera

final class MultiPageAtlasTests: XCTestCase {

    /// Indexed grid plane in XZ (normal +Y) — `side`×`side` quads at `spacing`,
    /// so its area is exactly (side·spacing)².
    private static func planeMesh(side: Int, spacing: Float) -> MeshData {
        var mesh = MeshData()
        for z in 0...side {
            for x in 0...side {
                mesh.vertices.append(SIMD3(Float(x) * spacing, 0, Float(z) * spacing))
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

    /// A duplicated-corner (soup) mesh of `triCount` triangles — the shape every
    /// baked TexturedMesh actually has.
    private static func soupMesh(triCount: Int) -> MeshData {
        var mesh = MeshData()
        for t in 0..<triCount {
            let x = Float(t) * 0.5
            mesh.vertices.append(contentsOf: [SIMD3(x, 0, 0), SIMD3(x + 0.4, 0, 0),
                                              SIMD3(x, 0, 0.4)])
            mesh.normals.append(contentsOf: repeatElement(SIMD3(0, 1, 0), count: 3))
            let base = UInt32(t * 3)
            mesh.indices.append(contentsOf: [base, base + 1, base + 2])
        }
        return mesh
    }

    private static func texturedSoup(triCount: Int, pages: Int) -> TexturedMesh {
        let mesh = soupMesh(triCount: triCount)
        let uvs = (0..<mesh.vertices.count).map { _ in SIMD2<Float>(0.5, 0.5) }
        // Distinct bytes per page so a mix-up is visible rather than silent.
        let textures = (0..<pages).map { Data([UInt8($0), 0xAA, 0xBB]) }
        let pageOfTri = (0..<triCount).map { UInt8($0 % pages) }
        return TexturedMesh(mesh: mesh, uvs: uvs, textures: textures,
                            textureSize: 512, pageOfTri: pageOfTri)
    }

    // MARK: - The ceiling, and what pages buy

    /// Many separate flat patches — a mesh whose UV unwrap produces one chart per
    /// patch instead of a single welded sheet.
    ///
    /// A page is a packing destination, and the shelf packer spills whole CHARTS:
    /// one chart can never straddle two sheets. So `planeMesh` cannot page however
    /// large it is — a continuous plane unwraps to exactly one chart, which lands
    /// on page 0 and drags the density down with it. A real room surface arrives as
    /// thousands of charts (25 404 on the last big export), and that is what pages
    /// actually buy density for.
    private static func patchesMesh(patchesPerSide: Int, patchSize: Float) -> MeshData {
        var mesh = MeshData()
        for iz in 0..<patchesPerSide {
            for ix in 0..<patchesPerSide {
                // Gap between patches, so no two share a vertex and each unwraps
                // into its own chart.
                let x0 = Float(ix) * patchSize * 2, z0 = Float(iz) * patchSize * 2
                let base = UInt32(mesh.vertices.count)
                for (dx, dz) in [(Float(0), Float(0)), (patchSize, 0),
                                 (0, patchSize), (patchSize, patchSize)] {
                    mesh.vertices.append(SIMD3(x0 + dx, 0, z0 + dz))
                    mesh.normals.append(SIMD3(0, 1, 0))
                }
                mesh.indices.append(contentsOf: [base, base + 2, base + 1,
                                                 base + 1, base + 2, base + 3])
            }
        }
        return mesh
    }

    /// The single-sheet density ceiling is pure area accounting, so a surface
    /// large enough to hit it gains √N from N pages. Measured on real exports at
    /// 119 m²: 514 → 727 → 1028 texels/m for 1 → 2 → 4 pages (1.00×/1.41×/2.00×).
    func testLargeSurfaceSpendsPagesAndGainsSqrtN() throws {
        // 900 patches of 1 m²: 900 m² of surface in 900 charts, far past what one
        // 1024² sheet can resolve at target.
        let mesh = Self.patchesMesh(patchesPerSide: 30, patchSize: 1.0)
        let single = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 1024,
                                                    minTexSize: 256, maxPages: 1))
        let paged = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 1024,
                                                   minTexSize: 256, maxPages: 4))
        XCTAssertEqual(single.pageCount, 1)
        XCTAssertGreaterThan(paged.pageCount, 1, "an area-limited surface must spend pages")

        let gain = paged.density / single.density
        let expected = Float(paged.pageCount).squareRoot()
        XCTAssertEqual(gain, expected, accuracy: expected * 0.25,
                       "N pages buy √N texel density")
    }

    /// Handing a small subject a page budget must be a no-op: its density is
    /// already at target, so extra sheets would only let the minTexSize floor
    /// inflate it past anything the keyframes carry (0.11 m² once burned three).
    func testSmallObjectRefusesExtraPages() throws {
        let mesh = Self.planeMesh(side: 8, spacing: 0.04)   // 0.32 m × 0.32 m
        let paged = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 4096,
                                                   maxPages: 4))
        XCTAssertEqual(paged.pageCount, 1)
        XCTAssertTrue(paged.pageOfTri.isEmpty, "no page map without pages")
    }

    /// Every triangle lands on exactly one real page, and no UV escapes its sheet.
    func testPagedLayoutIsSelfConsistent() throws {
        let mesh = Self.planeMesh(side: 40, spacing: 1.0)
        let layout = try XCTUnwrap(ChartAtlas.build(mesh: mesh, maxTexSize: 1024,
                                                    minTexSize: 256, maxPages: 4))
        try XCTSkipIf(layout.pageCount == 1)
        let triCount = mesh.indices.count / 3
        XCTAssertEqual(layout.pageOfTri.count, triCount)
        XCTAssertTrue(layout.pageOfTri.allSatisfy { Int($0) < layout.pageCount })
        XCTAssertEqual(Set(layout.pageOfTri).count, layout.pageCount,
                       "every counted page must actually carry triangles")
        for uv in layout.uvPx {
            XCTAssertLessThanOrEqual(max(uv.x, uv.y), Float(layout.texSize) + 1)
        }
    }

    // MARK: - AtlasPage masking

    /// The adapter that lets every per-triangle atlas pass render one page
    /// without knowing paging exists: off-page triangles must visit no texel.
    func testAtlasPageVisitsOnlyItsOwnTriangles() {
        let mesh = Self.planeMesh(side: 4, spacing: 0.5)
        let triCount = mesh.indices.count / 3
        let base = StubLayout(texSize: 64, pages: 2,
                              pageOfTri: (0..<triCount).map { UInt8($0 % 2) })
        for page in 0..<2 {
            let masked = AtlasPage(base: base, index: page)
            for t in 0..<triCount {
                var visited = 0
                TextureAtlas.forEachTexel(corners: masked.corners(of: t),
                                          texSize: masked.texSize) { _, _, _, _, _ in
                    visited += 1
                }
                if base.page(of: t) == page {
                    XCTAssertGreaterThan(visited, 0, "on-page triangle must rasterise")
                } else {
                    XCTAssertEqual(visited, 0, "off-page triangle must be skipped")
                }
            }
        }
    }

    private struct StubLayout: AtlasLayout {
        let texSize: Int
        let pages: Int
        let pageOfTri: [UInt8]
        var pageCount: Int { pages }
        func page(of t: Int) -> Int { Int(pageOfTri[t]) }
        func corners(of t: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
            (SIMD2(2, 2), SIMD2(20, 2), SIMD2(2, 20))
        }
    }

    // MARK: - Model

    func testSinglePageConvenienceCarriesNoPageMap() {
        let mesh = Self.soupMesh(triCount: 4)
        let textured = TexturedMesh(mesh: mesh, uvs: Array(repeating: .zero, count: 12),
                                    texturePNG: Data([1, 2, 3]), textureSize: 256)
        XCTAssertEqual(textured.pageCount, 1)
        XCTAssertTrue(textured.pageOfTri.isEmpty)
        XCTAssertEqual(textured.texturePNG, Data([1, 2, 3]))
        XCTAssertEqual(textured.page(of: 3), 0)
        XCTAssertEqual(textured.trianglesByPage(), [[0, 1, 2, 3]])
    }

    func testTrianglesByPagePartitionsEveryTriangleExactlyOnce() {
        let textured = Self.texturedSoup(triCount: 9, pages: 3)
        let groups = textured.trianglesByPage()
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.flatMap { $0 }.sorted(), Array(0..<9).map(UInt32.init))
        for (page, group) in groups.enumerated() {
            for t in group { XCTAssertEqual(textured.page(of: Int(t)), page) }
        }
    }

    func testPageOfVertexFollowsItsTriangle() {
        let textured = Self.texturedSoup(triCount: 6, pages: 2)
        let vertexPage = textured.pageOfVertex()
        XCTAssertEqual(vertexPage.count, textured.mesh.vertices.count)
        for t in 0..<6 {
            for k in 0..<3 {
                XCTAssertEqual(Int(vertexPage[t * 3 + k]), textured.page(of: t))
            }
        }
    }

    /// A page map without pages to choose between is meaningless, and every
    /// consumer treats "empty" as the single-page fast path.
    func testPageMapIsDroppedWhenThereIsOnlyOnePage() {
        let mesh = Self.soupMesh(triCount: 3)
        let textured = TexturedMesh(mesh: mesh, uvs: Array(repeating: .zero, count: 9),
                                    textures: [Data([9])], textureSize: 128,
                                    pageOfTri: [0, 0, 0])
        XCTAssertTrue(textured.pageOfTri.isEmpty)
    }

    // MARK: - Codec

    func testPagedMeshSurvivesSaveAndReload() throws {
        let textured = Self.texturedSoup(triCount: 8, pages: 3)
        let encoded = MeshStore.encode(textured.mesh, textured: textured)
        let loaded = try MeshStore.decodeFull(encoded)
        let out = try XCTUnwrap(loaded.textured)

        XCTAssertEqual(out.pageCount, 3)
        XCTAssertEqual(out.textures, textured.textures, "every page survives, in order")
        XCTAssertEqual(out.pageOfTri, textured.pageOfTri)
        XCTAssertEqual(out.textureSize, textured.textureSize)
        XCTAssertEqual(out.uvs.count, textured.uvs.count)
        XCTAssertEqual(loaded.mesh.indices, textured.mesh.indices)
    }

    /// Paging must not disturb what an ordinary save writes: an unpaged mesh
    /// stays at format v2, byte for byte.
    func testUnpagedSaveStaysAtVersionTwo() throws {
        let mesh = Self.soupMesh(triCount: 5)
        let textured = TexturedMesh(mesh: mesh,
                                    uvs: Array(repeating: SIMD2<Float>(0.25, 0.75),
                                               count: mesh.vertices.count),
                                    texturePNG: Data([0xFF, 0xD8, 0xFF, 0x01]),
                                    textureSize: 64)
        let encoded = MeshStore.encode(mesh, textured: textured)
        let version = encoded.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(version, 2, "single-page saves keep the pre-paging format")

        let out = try XCTUnwrap(try MeshStore.decodeFull(encoded).textured)
        XCTAssertEqual(out.pageCount, 1)
        XCTAssertEqual(out.texturePNG, textured.texturePNG)
    }

    func testPagedSaveMovesToVersionThree() throws {
        let textured = Self.texturedSoup(triCount: 4, pages: 2)
        let encoded = MeshStore.encode(textured.mesh, textured: textured)
        let version = encoded.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        XCTAssertEqual(version, 3)
    }

    // MARK: - Export

    /// Each page becomes its own primitive/material/image, and between them the
    /// primitives still cover every triangle exactly once.
    func testGLBEmitsOnePrimitivePerPage() throws {
        let textured = Self.texturedSoup(triCount: 9, pages: 3)
        let glb = try TexturedMeshExporter.glbData(from: textured)
        XCTAssertEqual([UInt8](glb.prefix(4)), [0x67, 0x6C, 0x54, 0x46])

        let json = try Self.glbJSON(glb)
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let primitives = try XCTUnwrap(meshes[0]["primitives"] as? [[String: Any]])
        XCTAssertEqual(primitives.count, 3)
        XCTAssertEqual((json["materials"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((json["images"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((json["textures"] as? [[String: Any]])?.count, 3)

        // Every primitive binds its own material, shares the attribute accessors,
        // and the index accessors together cover all 9 triangles.
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        var totalIndices = 0
        for (page, primitive) in primitives.enumerated() {
            XCTAssertEqual(primitive["material"] as? Int, page)
            let attributes = try XCTUnwrap(primitive["attributes"] as? [String: Int])
            XCTAssertEqual(attributes["POSITION"], 3, "attributes are shared across pages")
            let indexAccessor = try XCTUnwrap(primitive["indices"] as? Int)
            totalIndices += try XCTUnwrap(accessors[indexAccessor]["count"] as? Int)
        }
        XCTAssertEqual(totalIndices, 27, "3 indices × 9 triangles, no triangle lost or doubled")
    }

    func testGLBSinglePageStillEmitsOnePrimitive() throws {
        let mesh = Self.soupMesh(triCount: 4)
        let textured = TexturedMesh(mesh: mesh,
                                    uvs: Array(repeating: SIMD2<Float>(0.5, 0.5),
                                               count: mesh.vertices.count),
                                    texturePNG: Data([0xFF, 0xD8, 0xFF, 0x42]),
                                    textureSize: 128)
        let json = try Self.glbJSON(try TexturedMeshExporter.glbData(from: textured))
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        XCTAssertEqual((meshes[0]["primitives"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((json["materials"] as? [[String: Any]])?.count, 1)
    }

    /// Saved models predate the JPEG atlas, so the exporter must label what is
    /// actually there rather than assuming.
    func testGLBLabelsEachImageByItsRealFormat() throws {
        let mesh = Self.soupMesh(triCount: 2)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let textured = TexturedMesh(mesh: mesh,
                                    uvs: Array(repeating: SIMD2<Float>(0.5, 0.5),
                                               count: mesh.vertices.count),
                                    textures: [png, jpeg], textureSize: 64,
                                    pageOfTri: [0, 1])
        let json = try Self.glbJSON(try TexturedMeshExporter.glbData(from: textured))
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(images[1]["mimeType"] as? String, "image/jpeg")
    }

    func testSceneKitGeometryGetsOneMaterialPerPage() throws {
        // Real encoded images — SceneKit needs a decodable UIImage per page.
        let pixels = [UInt8](repeating: 200, count: 8 * 8 * 4)
        let image = try XCTUnwrap(TextureAtlas.encodeAtlas(pixels: pixels, size: 8))
        let mesh = Self.soupMesh(triCount: 6)
        let textured = TexturedMesh(mesh: mesh,
                                    uvs: Array(repeating: SIMD2<Float>(0.5, 0.5),
                                               count: mesh.vertices.count),
                                    textures: [image, image], textureSize: 8,
                                    pageOfTri: [0, 0, 0, 1, 1, 1])
        let geometry = try XCTUnwrap(TexturedMeshExporter.geometry(from: textured))
        XCTAssertEqual(geometry.elements.count, 2)
        XCTAssertEqual(geometry.materials.count, 2)
        XCTAssertEqual(geometry.elements.map(\.primitiveCount), [3, 3])
    }

    // MARK: - Encoding

    func testAtlasEncodesAsJPEGAndPaletteStaysPNG() throws {
        let pixels = [UInt8](repeating: 128, count: 16 * 16 * 4)
        let atlas = try XCTUnwrap(TextureAtlas.encodeAtlas(pixels: pixels, size: 16))
        let png = try XCTUnwrap(TextureAtlas.encodePNG(pixels: pixels, size: 16))
        XCTAssertEqual([UInt8](atlas.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertEqual([UInt8](png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(TextureAtlas.imageMIMEType(atlas), "image/jpeg")
        XCTAssertEqual(TextureAtlas.imageMIMEType(png), "image/png")
    }

    /// The reason the atlas moved off PNG at all: a paged sheet is stored and
    /// shared N times over.
    func testJPEGAtlasIsSubstantiallySmallerThanPNG() throws {
        // Genuinely photographic content: smooth low-frequency colour plus fine
        // random grain. The previous fixture claimed to be this but was a periodic
        // sawtooth (`x*7 + y*3 mod 256`) — the one shape where PNG wins outright:
        // its filters predict a ramp exactly (1.7 kB) while JPEG has to encode the
        // ringing at every wrap (29 kB). A photo has neither property; the grain is
        // what PNG cannot compress and JPEG is entitled to discard.
        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        var state: UInt64 = 0xA11A5
        for y in 0..<256 {
            for x in 0..<256 {
                let o = (y * 256 + x) * 4
                let fx = Float(x) / 255, fy = Float(y) / 255
                let base = SIMD3<Float>(90 + 120 * fx, 70 + 100 * fy,
                                        140 - 60 * (fx + fy) / 2)
                for c in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let grain = Float((state >> 40) % 25) - 12
                    pixels[o + c] = UInt8(min(max(base[c] + grain, 0), 255))
                }
                pixels[o + 3] = 255
            }
        }
        let jpeg = try XCTUnwrap(TextureAtlas.encodeAtlas(pixels: pixels, size: 256))
        let png = try XCTUnwrap(TextureAtlas.encodePNG(pixels: pixels, size: 256))
        XCTAssertLessThan(jpeg.count, png.count)
    }

    // MARK: - Helpers

    /// Parses the JSON chunk out of a GLB container.
    private static func glbJSON(_ glb: Data) throws -> [String: Any] {
        let jsonLength = Int(glb.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        })
        let chunk = glb.subdata(in: 20..<(20 + jsonLength))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: chunk) as? [String: Any])
    }
}
