//
//  ModelStudioBaker.swift
//  Magic Camera
//
//  Turns a Model Studio stage into a single saveable mesh with a texture.
//
//  Two paths. When no object carries a photo texture, colours are baked into a
//  tiny stripe-palette atlas (one full-height stripe per distinct colour, every
//  vertex pinned to its stripe centre — V-flip immune, no bilinear bleed). When
//  at least one object is photo-textured (an imported scan), the stage is baked
//  into a square grid atlas: each object gets one cell holding either its
//  scaled photo or a solid colour, and its UVs are scaled into that cell. The
//  per-cell mapping inherits each object's original UV relationship, so an
//  imported scan keeps its photographs through save and USDZ export.
//

import CoreGraphics
import Foundation
import ImageIO
import simd

enum ModelStudioBaker {
    /// Stripe-palette atlas: 16 stripes of 16 px on a 256 px square.
    private static let paletteTexture = 256
    private static let stripeCount = 16

    /// A baked stage: the merged mesh plus the texture that colours it.
    struct Baked {
        let mesh: MeshData
        let textured: TexturedMesh?
    }

    /// Concatenates every (non-empty) object mesh into one, in stage order —
    /// the order the bakers assign UVs in.
    static func merge(_ objects: [StudioObject]) -> MeshData {
        objects.reduce(MeshData()) { merged, object in
            merged.appending(object.mesh)
        }
    }

    /// Bakes the whole stage. Picks the photo-grid atlas when any object is
    /// textured, the cheaper stripe palette otherwise. Returns nil only when
    /// the stage has no geometry.
    static func bake(_ objects: [StudioObject]) -> Baked? {
        let contributing = objects.filter { !$0.mesh.isEmpty }
        guard !contributing.isEmpty else { return nil }
        let merged = merge(contributing)
        guard !merged.isEmpty else { return nil }

        if contributing.contains(where: { $0.texturedMesh != nil }),
           let textured = bakeGrid(contributing, merged: merged) {
            return Baked(mesh: merged, textured: textured)
        }
        return Baked(mesh: merged, textured: bakePalette(contributing, merged: merged))
    }

    // MARK: - Stripe palette (colours only)

    /// Builds the palette texture and per-vertex UVs for `merged` (which must
    /// be the concatenation of `objects`' meshes, in order). Returns nil when
    /// the stage is empty or PNG encoding fails.
    static func bakePalette(_ objects: [StudioObject], merged: MeshData) -> TexturedMesh? {
        let contributing = objects.filter { !$0.mesh.isEmpty }
        guard !merged.isEmpty, !contributing.isEmpty else { return nil }

        // Distinct colours → stripe indices (first-come order, capped at the
        // stripe count; overflow reuses the nearest existing stripe).
        var stripes: [SIMD3<Float>] = []
        var stripeOfObject: [Int] = []
        for object in contributing {
            if let existing = stripes.firstIndex(where: { simd_length($0 - object.color) < 0.01 }) {
                stripeOfObject.append(existing)
            } else if stripes.count < stripeCount {
                stripeOfObject.append(stripes.count)
                stripes.append(object.color)
            } else {
                let nearest = stripes.indices.min {
                    simd_length(stripes[$0] - object.color) < simd_length(stripes[$1] - object.color)
                } ?? 0
                stripeOfObject.append(nearest)
            }
        }

        let stripeWidth = paletteTexture / stripeCount
        var pixels = [UInt8](repeating: 0, count: paletteTexture * paletteTexture * 4)
        for (index, color) in stripes.enumerated() {
            for y in 0..<paletteTexture {
                for x in (index * stripeWidth)..<((index + 1) * stripeWidth) {
                    TextureAtlas.write(color, x: x, y: y, texSize: paletteTexture, into: &pixels)
                }
            }
        }
        TextureAtlas.fillGutters(pixels: &pixels, size: paletteTexture)
        guard let png = TextureAtlas.encodePNG(pixels: pixels, size: paletteTexture) else { return nil }

        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity(merged.vertices.count)
        for (objectIndex, object) in contributing.enumerated() {
            let u = (Float(stripeOfObject[objectIndex]) + 0.5) / Float(stripeCount)
            uvs.append(contentsOf: repeatElement(SIMD2<Float>(u, 0.5),
                                                 count: object.mesh.vertices.count))
        }
        guard uvs.count == merged.vertices.count else { return nil }
        return TexturedMesh(mesh: merged, uvs: uvs,
                            texturePNG: png, textureSize: paletteTexture)
    }

    // MARK: - Re-bake after a topology change

    /// Re-bakes the photographic colour of `sources` onto `mesh` after an edit
    /// (smooth / reduce / CSG) dropped the original UVs. Each source's atlas is
    /// sampled into a per-vertex colour cloud; the merged cloud then bakes a
    /// fresh atlas onto the new mesh by nearest-surface colour. Returns nil when
    /// there's nothing to sample or baking fails. Heavy — run off the main thread.
    static func rebake(_ mesh: MeshData, fromSources sources: [TexturedMesh]) -> TexturedMesh? {
        guard !mesh.isEmpty else { return nil }
        var cloud = PointCloud()
        for source in sources {
            guard let colours = colorCloud(from: source) else { continue }
            cloud.reserveCapacity(cloud.count + colours.count)
            for i in 0..<colours.count {
                cloud.append(position: colours.positions[i], color: colours.colors[i],
                             confidence: colours.confidences[i])
            }
        }
        guard !cloud.isEmpty else { return nil }
        return MeshTextureBaker.bake(mesh: mesh, cloud: cloud)
    }

    /// Samples a textured mesh's atlas at each vertex's UV into a colour cloud —
    /// the bridge that carries photographs onto a re-topologised mesh. Uses the
    /// app-wide UV convention (uv = pixel / size, top-down; see TextureAtlas).
    static func colorCloud(from textured: TexturedMesh) -> PointCloud? {
        guard textured.uvs.count == textured.mesh.vertices.count,
              let decoded = decode(textured.texturePNG) else { return nil }
        let w = decoded.width, h = decoded.height
        var cloud = PointCloud()
        cloud.reserveCapacity(textured.mesh.vertices.count)
        for i in 0..<textured.mesh.vertices.count {
            let uv = textured.uvs[i]
            let px = min(max(Int(uv.x * Float(w)), 0), w - 1)
            let py = min(max(Int(uv.y * Float(h)), 0), h - 1)
            let o = (py * w + px) * 4
            let colour = SIMD3<Float>(Float(decoded.pixels[o]) / 255,
                                      Float(decoded.pixels[o + 1]) / 255,
                                      Float(decoded.pixels[o + 2]) / 255)
            cloud.append(position: textured.mesh.vertices[i], color: colour, confidence: 1)
        }
        return cloud
    }

    // MARK: - Photo grid (mixed photo + colour)

    /// Packs each object into one cell of a square atlas: its scaled photo, or
    /// a solid colour fill, with UVs scaled into the cell. Buffers are handled
    /// top-down throughout (matching `TextureAtlas.encodePNG`), so each cell
    /// reproduces its source's original UV mapping exactly.
    private static func bakeGrid(_ objects: [StudioObject], merged: MeshData) -> TexturedMesh? {
        let grid = Int(ceil(Double(objects.count).squareRoot()))
        guard grid >= 1 else { return nil }
        // Keep the atlas at a sane size: smaller cells as the grid grows.
        let cell = max(64, min(256, 1024 / grid))
        let side = grid * cell
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity(merged.vertices.count)

        for (index, object) in objects.enumerated() {
            let col = index % grid
            let row = index / grid           // from the top — buffers are top-down
            let x0 = col * cell, y0 = row * cell

            if let textured = object.texturedMesh,
               let decoded = decode(textured.texturePNG) {
                // Nearest-neighbour blit of the photo into the cell.
                for ty in 0..<cell {
                    let sy = min(ty * decoded.height / cell, decoded.height - 1)
                    for tx in 0..<cell {
                        let sx = min(tx * decoded.width / cell, decoded.width - 1)
                        let src = (sy * decoded.width + sx) * 4
                        let dst = ((y0 + ty) * side + x0 + tx) * 4
                        pixels[dst] = decoded.pixels[src]
                        pixels[dst + 1] = decoded.pixels[src + 1]
                        pixels[dst + 2] = decoded.pixels[src + 2]
                        pixels[dst + 3] = 255
                    }
                }
                let scale = SIMD2<Float>(1 / Float(grid), 1 / Float(grid))
                let offset = SIMD2<Float>(Float(col) / Float(grid), Float(row) / Float(grid))
                for uv in textured.uvs {
                    // Clamp into the unit cell so a stray UV can't bleed across.
                    let clamped = simd_clamp(uv, SIMD2<Float>(0, 0), SIMD2<Float>(1, 1))
                    uvs.append(offset + clamped * scale)
                }
            } else {
                // Solid colour cell; pin every vertex to its centre.
                for ty in 0..<cell {
                    for tx in 0..<cell {
                        TextureAtlas.write(object.color, x: x0 + tx, y: y0 + ty,
                                           texSize: side, into: &pixels)
                    }
                }
                let centre = SIMD2<Float>((Float(col) + 0.5) / Float(grid),
                                          (Float(row) + 0.5) / Float(grid))
                uvs.append(contentsOf: repeatElement(centre, count: object.mesh.vertices.count))
            }
        }

        TextureAtlas.fillGutters(pixels: &pixels, size: side)
        guard uvs.count == merged.vertices.count,
              let png = TextureAtlas.encodePNG(pixels: pixels, size: side) else { return nil }
        return TexturedMesh(mesh: merged, uvs: uvs, texturePNG: png, textureSize: side)
    }

    /// Decodes a PNG into a top-down premultiplied-RGBA buffer (row 0 = top,
    /// matching `encodePNG`'s input order). A plain draw into a fresh bitmap
    /// context keeps that orientation — the upside-down trap only bites flipped
    /// UIKit contexts, not raw CGBitmapContexts.
    private static func decode(_ png: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? (pixels, width, height) : nil
    }
}
