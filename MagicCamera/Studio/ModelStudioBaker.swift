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
        // Densify each source's colour samples so the re-bake stays sharp even
        // when the source mesh is low-poly — budget the total so a heavy scan
        // doesn't explode the cloud. samplesPerTri = (s+1)(s+2)/2 for s≥1.
        let totalTris = sources.reduce(0) { $0 + $1.mesh.triangleCount }
        let budget = 800_000
        var subdivisions = 4
        while subdivisions > 0, totalTris * (subdivisions + 1) * (subdivisions + 2) / 2 > budget {
            subdivisions -= 1
        }
        var cloud = PointCloud()
        for source in sources {
            guard let colours = colorCloud(from: source, subdivisions: subdivisions) else { continue }
            cloud.reserveCapacity(cloud.count + colours.count)
            for i in 0..<colours.count {
                cloud.append(position: colours.positions[i], color: colours.colors[i],
                             confidence: colours.confidences[i])
            }
        }
        guard !cloud.isEmpty else { return nil }
        return MeshTextureBaker.bake(mesh: mesh, cloud: cloud)
    }

    /// Samples a textured mesh's atlas into a colour cloud — the bridge that
    /// carries photographs onto a re-topologised mesh. `subdivisions` 0 samples
    /// one colour per vertex; n > 0 samples an (n+1)-row barycentric grid across
    /// every triangle for a dense colour field. Uses the app-wide UV convention
    /// (uv = pixel / size, top-down; see TextureAtlas).
    /// A paged atlas is walked one page at a time: positions are laid out first,
    /// then each sheet is decoded, used to colour only the samples that belong to
    /// it, and released. Decoding all pages at once would cost pageCount × the
    /// atlas — a gigabyte for four 8192² sheets — for a routine retopology.
    static func colorCloud(from textured: TexturedMesh, subdivisions: Int = 0) -> PointCloud? {
        guard textured.uvs.count == textured.mesh.vertices.count else { return nil }
        let mesh = textured.mesh

        // Sample sites: world position, its UV, and the page that UV indexes.
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var pages: [UInt8] = []
        if subdivisions <= 0 {
            let vertexPage = textured.pageOfVertex()
            positions = mesh.vertices
            uvs = textured.uvs
            pages = vertexPage.isEmpty
                ? [UInt8](repeating: 0, count: mesh.vertices.count) : vertexPage
        } else {
            let triCount = mesh.indices.count / 3
            let steps = subdivisions
            let capacity = triCount * (steps + 1) * (steps + 2) / 2
            positions.reserveCapacity(capacity)
            uvs.reserveCapacity(capacity)
            pages.reserveCapacity(capacity)
            for t in 0..<triCount {
                let i0 = Int(mesh.indices[t * 3]), i1 = Int(mesh.indices[t * 3 + 1])
                let i2 = Int(mesh.indices[t * 3 + 2])
                let p0 = mesh.vertices[i0], p1 = mesh.vertices[i1], p2 = mesh.vertices[i2]
                let uv0 = textured.uvs[i0], uv1 = textured.uvs[i1], uv2 = textured.uvs[i2]
                let page = UInt8(textured.page(of: t))
                for a in 0...steps {
                    for b in 0...(steps - a) {
                        let l0 = Float(a) / Float(steps)
                        let l1 = Float(b) / Float(steps)
                        let l2 = 1 - l0 - l1
                        positions.append(p0 * l0 + p1 * l1 + p2 * l2)
                        uvs.append(uv0 * l0 + uv1 * l1 + uv2 * l2)
                        pages.append(page)
                    }
                }
            }
        }

        var colors = [SIMD3<Float>](repeating: SIMD3<Float>(repeating: 0.6), count: positions.count)
        for page in 0..<textured.pageCount {
            guard let decoded = decode(textured.textures[page]) else { return nil }
            let w = decoded.width, h = decoded.height
            for i in 0..<positions.count where Int(pages[i]) == page {
                let uv = uvs[i]
                let px = min(max(Int(uv.x * Float(w)), 0), w - 1)
                let py = min(max(Int(uv.y * Float(h)), 0), h - 1)
                let o = (py * w + px) * 4
                colors[i] = SIMD3<Float>(Float(decoded.pixels[o]) / 255,
                                         Float(decoded.pixels[o + 1]) / 255,
                                         Float(decoded.pixels[o + 2]) / 255)
            }
        }

        var cloud = PointCloud()
        cloud.reserveCapacity(positions.count)
        for i in 0..<positions.count {
            cloud.append(position: positions[i], color: colors[i], confidence: 1)
        }
        return cloud
    }

    // MARK: - Photo grid (mixed photo + colour)

    /// Packs each object into one cell of a square atlas: its scaled photo, or
    /// a solid colour fill, with UVs scaled into the cell. Buffers are handled
    /// top-down throughout (matching `TextureAtlas.encodePNG`), so each cell
    /// reproduces its source's original UV mapping exactly.
    private static func bakeGrid(_ objects: [StudioObject], merged: MeshData) -> TexturedMesh? {
        // One cell per (object, atlas PAGE). A paged object's UVs are normalised
        // within their own sheet, so two pages both span [0,1]² — folding them
        // into a single cell would sample the wrong sheet, giving wrong colours
        // rather than merely softer ones. Each page therefore gets its own cell,
        // and a vertex is mapped to the cell of the page its triangle uses.
        var cellOfObject: [Int] = []
        var cellSources: [(object: Int, page: Int)] = []
        for (i, object) in objects.enumerated() {
            cellOfObject.append(cellSources.count)
            let pages = object.texturedMesh?.pageCount ?? 1
            for page in 0..<pages { cellSources.append((i, page)) }
        }
        let grid = Int(ceil(Double(cellSources.count).squareRoot()))
        guard grid >= 1 else { return nil }
        // Keep the atlas at a sane size: smaller cells as the grid grows.
        let cell = max(64, min(256, 1024 / grid))
        let side = grid * cell
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        @inline(__always)
        func cellOrigin(_ index: Int) -> (x: Int, y: Int) {
            // Row from the top — buffers are top-down.
            ((index % grid) * cell, (index / grid) * cell)
        }
        func fillSolid(_ index: Int, color: SIMD3<Float>) {
            let (x0, y0) = cellOrigin(index)
            for ty in 0..<cell {
                for tx in 0..<cell {
                    TextureAtlas.write(color, x: x0 + tx, y: y0 + ty,
                                       texSize: side, into: &pixels)
                }
            }
        }

        // Blit each cell, decoding one page at a time so a multi-page room never
        // has more than one sheet resident. An object whose atlas won't decode
        // falls back to its flat colour across all of its cells.
        var usesPhoto = [Bool](repeating: false, count: objects.count)
        for (i, object) in objects.enumerated() {
            guard let textured = object.texturedMesh else {
                fillSolid(cellOfObject[i], color: object.color)
                continue
            }
            var decodedAll = true
            for page in 0..<textured.pageCount {
                guard let decoded = decode(textured.textures[page]) else {
                    decodedAll = false
                    break
                }
                let (x0, y0) = cellOrigin(cellOfObject[i] + page)
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
            }
            usesPhoto[i] = decodedAll
            if !decodedAll {
                for page in 0..<textured.pageCount {
                    fillSolid(cellOfObject[i] + page, color: object.color)
                }
            }
        }

        // UVs, in object order so they line up with `merged`'s vertices.
        var uvs: [SIMD2<Float>] = []
        uvs.reserveCapacity(merged.vertices.count)
        let scale = SIMD2<Float>(1 / Float(grid), 1 / Float(grid))
        for (i, object) in objects.enumerated() {
            guard usesPhoto[i], let textured = object.texturedMesh else {
                // Solid colour cell; pin every vertex to its centre.
                let index = cellOfObject[i]
                let centre = SIMD2<Float>((Float(index % grid) + 0.5) / Float(grid),
                                          (Float(index / grid) + 0.5) / Float(grid))
                uvs.append(contentsOf: repeatElement(centre, count: object.mesh.vertices.count))
                continue
            }
            let vertexPage = textured.pageOfVertex()
            for (v, uv) in textured.uvs.enumerated() {
                let index = cellOfObject[i] + (vertexPage.isEmpty ? 0 : Int(vertexPage[v]))
                let offset = SIMD2<Float>(Float(index % grid) / Float(grid),
                                          Float(index / grid) / Float(grid))
                // Clamp into the unit cell so a stray UV can't bleed across.
                let clamped = simd_clamp(uv, SIMD2<Float>(0, 0), SIMD2<Float>(1, 1))
                uvs.append(offset + clamped * scale)
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
