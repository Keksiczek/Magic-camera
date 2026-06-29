//
//  TextureSeamLevelerTests.swift
//  MagicCameraTests
//
//  Cross-view colour seam levelling: two adjacent charts baked different colours
//  should be pulled toward a shared colour at their seam.
//

import XCTest
import simd
@testable import MagicCamera

final class TextureSeamLevelerTests: XCTestCase {

    func testLevelerPullsAdjacentChartsTogether() {
        // Two triangles sharing edge (0,0,0)–(1,0,0).
        let verts: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),     // t0
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0)     // t1
        ]
        let mesh = MeshData(vertices: verts, normals: [], indices: [0, 1, 2, 3, 4, 5])
        let layout = TextureAtlas.Layout(triangleCount: 2, requested: 256)
        let geometry = TextureAtlas.buildGeometry(mesh: mesh, layout: layout)

        var pixels = [UInt8](repeating: 0, count: layout.texSize * layout.texSize * 4)
        let red = SIMD3<Float>(0.8, 0.2, 0.2), blue = SIMD3<Float>(0.2, 0.2, 0.8)
        TextureAtlas.forEachTexel(corners: layout.corners(of: 0), texSize: layout.texSize) { px, py, _, _, _ in
            TextureAtlas.write(red, x: px, y: py, texSize: layout.texSize, into: &pixels)
        }
        TextureAtlas.forEachTexel(corners: layout.corners(of: 1), texSize: layout.texSize) { px, py, _, _, _ in
            TextureAtlas.write(blue, x: px, y: py, texSize: layout.texSize, into: &pixels)
        }

        func chartCentre(_ t: Int) -> SIMD3<Float> {
            let c = layout.corners(of: t)
            let mid = (c.0 + c.1 + c.2) / 3
            let o = (Int(mid.y) * layout.texSize + Int(mid.x)) * 4
            return SIMD3(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2])) / 255
        }
        let r0 = chartCentre(0), b0 = chartCentre(1)
        TextureSeamLeveler.level(pixels: &pixels, size: layout.texSize, geometry: geometry, layout: layout)
        let r1 = chartCentre(0), b1 = chartCentre(1)

        XCTAssertGreaterThan(r1.z, r0.z + 0.05, "the red chart gains blue toward the seam consensus")
        XCTAssertGreaterThan(b1.x, b0.x + 0.05, "the blue chart gains red")
        XCTAssertLessThan(abs(r1.z - b1.z), abs(r0.z - b0.z), "the cross-seam colour gap shrinks")
    }
}
