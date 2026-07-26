//
//  TextureAtlas.swift
//  Magic Camera
//
//  Shared per-triangle UV-atlas machinery used by both texture bakers
//  (point-cloud colours and keyframe photos): chart layout (two triangles per
//  square cell with a gutter), duplicated-corner geometry + UVs, barycentric
//  texel iteration, and PNG encoding.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// What a texture bake needs from an atlas layout, regardless of how the charts
/// are arranged: the atlas edge length and each triangle's pixel-space chart
/// corners. Implemented by both the uniform-grid `TextureAtlas.Layout` and the
/// variable-resolution `AreaProportionalAtlas.Layout`, so baking, seam levelling,
/// de-lighting and gutter geometry run unchanged over either. `Sendable` so the
/// parallel bake passes can capture it.
protocol AtlasLayout: Sendable {
    var texSize: Int { get }
    /// How many `texSize`² pages the layout spans. A room's surface cannot reach
    /// a useful texel density inside one page: the ceiling is pure area
    /// accounting — `texSize · √(packEfficiency / surfaceArea)` — so 142 m² in a
    /// single 8192² sheet is bounded at ~1.8 mm/texel however well the charts
    /// pack. Splitting across N pages buys √N density for N× the texture memory,
    /// which the bake spends sequentially, one page at a time.
    var pageCount: Int { get }
    /// Which page triangle `t`'s chart was packed onto.
    func page(of t: Int) -> Int
    /// Pixel-space UV corners (a, b, c) of triangle `t`, within its own page.
    func corners(of t: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
}

extension AtlasLayout {
    /// The per-triangle layouts size every island to fit, so they always
    /// converge inside one page.
    var pageCount: Int { 1 }
    func page(of t: Int) -> Int { 0 }
}

/// One page of a multi-page layout, presented as a standalone single-page one.
///
/// Triangles belonging to another page report a degenerate off-canvas chart, so
/// every per-triangle atlas pass — the cloud fallback paint, the unwritten-texel
/// repair, de-lighting — skips them without knowing paging exists:
/// `forEachTexel`'s bounding-box guard rejects the corners before it touches a
/// texel. That is what lets the bake render one page at a time (peak memory
/// stays at a single sheet) while reusing the passes unchanged.
///
/// NOT for `TextureAtlas.buildGeometry`, which must see the FULL layout — every
/// triangle needs its real UVs — nor for `TextureSeamLeveler`, which *samples*
/// the corners it is given and so takes an explicit `page:` filter instead
/// (a degenerate chart would sample the page's origin texel as if it were the
/// triangle's colour).
struct AtlasPage: AtlasLayout {
    let base: any AtlasLayout
    let index: Int

    var texSize: Int { base.texSize }
    var pageCount: Int { 1 }
    func page(of t: Int) -> Int { 0 }

    func corners(of t: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        guard base.page(of: t) == index else { return Self.offCanvas }
        return base.corners(of: t)
    }

    /// Collapsed and left of the atlas origin: `forEachTexel` clamps minX to 0
    /// and maxX to a negative, so `minX <= maxX` fails and it returns having
    /// visited nothing.
    private static let offCanvas = (SIMD2<Float>(-8, -8), SIMD2<Float>(-8, -8),
                                    SIMD2<Float>(-8, -8))
}

/// One-bit-per-texel scratch for atlas passes that ADD or MULTIPLY in place
/// (seam leveler, de-lighter). With the UV-unwrapped ChartAtlas, adjacent
/// triangles in a chart share their edge texels, so a per-triangle pass would
/// apply its correction twice on the shared band — a faint line along every
/// interior edge. Claiming each texel once makes those passes idempotent under
/// any layout. ~8 MB transient for an 8192² atlas.
struct TexelClaimMask {
    private var bits: [UInt64]
    init(texelCount: Int) {
        bits = [UInt64](repeating: 0, count: (texelCount + 63) / 64)
    }
    /// True the first time `index` is claimed, false on any later attempt.
    @inline(__always)
    mutating func claim(_ index: Int) -> Bool {
        let word = index >> 6
        let mask: UInt64 = 1 << UInt64(index & 63)
        if bits[word] & mask != 0 { return false }
        bits[word] |= mask
        return true
    }
}

enum TextureAtlas {
    /// Atlas plan: cell grid sized for the triangle count, gutters included.
    struct Layout: AtlasLayout {
        let texSize: Int
        let gridSide: Int
        let cellPx: Float
        let gutter: Float

        init(triangleCount: Int, requested: Int? = nil,
             surfaceArea: Float? = nil, maxTexSize: Int = 4096) {
            gridSide = Int(ceil((Double(max(triangleCount, 1)) / 2).squareRoot()))
            // Texel budget per triangle drives sharpness. The old 12 px/cell at a
            // 2048 cap gave a dense reconstruction only ~7 px across each triangle
            // — soft, washed-out textures. 16 px/cell and a 4096 cap roughly
            // double the linear resolution (4× the texels) for detailed scans,
            // and a 1024 floor keeps small objects from baking into a tiny atlas.
            // Adaptive: a room's triangles are physically large (meshed coarse), so
            // a fixed 16 px/cell resolves far fewer texels-per-metre than a small
            // object's fine triangles — the "room textures are sparse" complaint.
            // `pxPerCell` therefore scales with the mean triangle's physical size
            // toward a target texel density: objects stay ~16 px, large surfaces
            // climb to `maxPxPerCell`, both bounded by `maxTexSize` (the surface
            // bake raises that ceiling; the memory-bound multi-view path keeps it
            // low). Without a measured area (legacy callers) it's the flat 16 px.
            // 4096²·4 B = 64 MB, 6144² = 144 MB transient — a one-shot review bake.
            let pxPerCell = Self.adaptivePxPerCell(surfaceArea: surfaceArea,
                                                   triangleCount: triangleCount)
            texSize = requested ?? min(max(Int(Float(gridSide) * pxPerCell), 1024), maxTexSize)
            cellPx = Float(texSize) / Float(gridSide)
            gutter = max(cellPx * 0.12, 1.5)
        }

        /// Texels per atlas cell, scaled from the mean triangle's physical edge
        /// toward a target texel density (≈15 px per cm of surface). Clamped so a
        /// fine-triangle object stays at the 16 px baseline and a coarse-triangle
        /// room climbs to 40 px. Returns the baseline when no area is measured.
        private static let baselinePxPerCell: Float = 16
        private static let maxPxPerCell: Float = 40
        private static func adaptivePxPerCell(surfaceArea: Float?,
                                              triangleCount: Int) -> Float {
            guard let area = surfaceArea, area > 0, triangleCount > 0 else {
                return baselinePxPerCell
            }
            let meanTriArea = area / Float(triangleCount)
            let edgeMetres = (2 * meanTriArea).squareRoot()   // right-triangle leg
            let texelsPerMetre: Float = 1500                  // ≈15 px / cm
            return min(max(edgeMetres * texelsPerMetre, baselinePxPerCell), maxPxPerCell)
        }

        /// Pixel-space UV corners of triangle `t` — lower-left or upper-right
        /// half of its cell, inset so neighbouring charts never bleed.
        func corners(of t: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
            let cellIndex = t / 2
            let cx = Float(cellIndex % gridSide) * cellPx
            let cy = Float(cellIndex / gridSide) * cellPx
            if t % 2 == 0 {
                return (SIMD2(cx + gutter, cy + gutter),
                        SIMD2(cx + cellPx - 2 * gutter, cy + gutter),
                        SIMD2(cx + gutter, cy + cellPx - 2 * gutter))
            }
            return (SIMD2(cx + cellPx - gutter, cy + cellPx - gutter),
                    SIMD2(cx + 2 * gutter, cy + cellPx - gutter),
                    SIMD2(cx + cellPx - gutter, cy + 2 * gutter))
        }
    }

    /// Mesh with duplicated per-corner vertices plus matching atlas UVs.
    struct Geometry {
        var mesh: MeshData
        var uvs: [SIMD2<Float>]
    }

    /// Builds the duplicated-corner geometry and UVs for `mesh` under `layout`.
    static func buildGeometry(mesh: MeshData, layout: some AtlasLayout) -> Geometry {
        let triCount = mesh.indices.count / 3
        var vertices = [SIMD3<Float>](); vertices.reserveCapacity(triCount * 3)
        var normals = [SIMD3<Float>](); normals.reserveCapacity(triCount * 3)
        var uvs = [SIMD2<Float>](); uvs.reserveCapacity(triCount * 3)
        var indices = [UInt32](); indices.reserveCapacity(triCount * 3)
        let hasNormals = mesh.normals.count == mesh.vertices.count
        let inv = 1 / Float(layout.texSize)

        for t in 0..<triCount {
            let i0 = Int(mesh.indices[t * 3])
            let i1 = Int(mesh.indices[t * 3 + 1])
            let i2 = Int(mesh.indices[t * 3 + 2])
            let w0 = mesh.vertices[i0], w1 = mesh.vertices[i1], w2 = mesh.vertices[i2]

            let base = UInt32(vertices.count)
            vertices.append(contentsOf: [w0, w1, w2])
            if hasNormals {
                normals.append(contentsOf: [mesh.normals[i0], mesh.normals[i1], mesh.normals[i2]])
            } else {
                let nf = simd_normalize(simd_cross(w1 - w0, w2 - w0))
                normals.append(contentsOf: [nf, nf, nf])
            }
            let p = layout.corners(of: t)
            uvs.append(contentsOf: [p.0 * inv, p.1 * inv, p.2 * inv])
            indices.append(contentsOf: [base, base + 1, base + 2])
        }
        return Geometry(mesh: MeshData(vertices: vertices, normals: normals, indices: indices),
                        uvs: uvs)
    }

    /// Visits every texel of a chart (plus a safety margin) with its clamped,
    /// renormalised barycentric coordinates — ready to interpolate world space.
    static func forEachTexel(corners: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
                             texSize: Int,
                             _ body: (_ px: Int, _ py: Int,
                                      _ l0: Float, _ l1: Float, _ l2: Float) -> Void) {
        let (a, b, c) = corners
        let minX = max(Int(min(a.x, b.x, c.x).rounded(.down)) - 1, 0)
        let maxX = min(Int(max(a.x, b.x, c.x).rounded(.up)) + 1, texSize - 1)
        let minY = max(Int(min(a.y, b.y, c.y).rounded(.down)) - 1, 0)
        let maxY = min(Int(max(a.y, b.y, c.y).rounded(.up)) + 1, texSize - 1)
        guard minX <= maxX, minY <= maxY else { return }

        let v0 = b - a, v1 = c - a
        let denom = v0.x * v1.y - v1.x * v0.y
        guard abs(denom) > 1e-9 else { return }
        let invDenom = 1 / denom
        // Accept a little outside the edges so bilinear lookups never hit void.
        let margin: Float = -0.18

        for py in minY...maxY {
            for px in minX...maxX {
                let q = SIMD2<Float>(Float(px) + 0.5, Float(py) + 0.5) - a
                var l1 = (q.x * v1.y - v1.x * q.y) * invDenom
                var l2 = (v0.x * q.y - q.x * v0.y) * invDenom
                var l0 = 1 - l1 - l2
                guard l0 >= margin, l1 >= margin, l2 >= margin else { continue }
                l0 = max(l0, 0); l1 = max(l1, 0); l2 = max(l2, 0)
                let sum = l0 + l1 + l2
                guard sum > 1e-9 else { continue }
                body(px, py, l0 / sum, l1 / sum, l2 / sum)
            }
        }
    }

    /// Flood-fills the unpainted texels (alpha 0) outward from the painted
    /// charts, breadth-first, so the gutters between charts take the colour of
    /// the nearest chart instead of staying black. Without this, bilinear and
    /// mipmap sampling at chart borders mixes in the void and draws a grid of
    /// dark seam lines across the textured model.
    ///
    /// `isCancelled` lets a backgrounded / memory-shed bake abandon the flood: on
    /// an 8192² atlas this is a 67 M-texel BFS, seconds of CPU with no other bail
    /// point, run once per page. Checked periodically; an abandoned fill just
    /// leaves some gutters black, and the caller discards the atlas anyway.
    /// Default never cancels — existing callers and tests are unchanged.
    static func fillGutters(pixels: inout [UInt8], size: Int,
                            isCancelled: () -> Bool = { false }) {
        guard size > 1, pixels.count == size * size * 4 else { return }
        var queue: [Int32] = []
        queue.reserveCapacity(size * 32)
        // Seed with every unpainted texel that touches a painted one.
        for y in 0..<size {
            let row = y * size
            for x in 0..<size {
                let i = row + x
                guard pixels[i * 4 + 3] == 0 else { continue }
                if (x > 0 && pixels[(i - 1) * 4 + 3] != 0)
                    || (x + 1 < size && pixels[(i + 1) * 4 + 3] != 0)
                    || (y > 0 && pixels[(i - size) * 4 + 3] != 0)
                    || (y + 1 < size && pixels[(i + size) * 4 + 3] != 0) {
                    queue.append(Int32(i))
                }
            }
        }
        var head = 0
        while head < queue.count {
            // ~65 k texels between checks — negligible overhead, sub-100 ms bail.
            if head & 0xFFFF == 0, isCancelled() { return }
            let i = Int(queue[head]); head += 1
            guard pixels[i * 4 + 3] == 0 else { continue }   // filled meanwhile
            let x = i % size, y = i / size
            var source = -1
            if x > 0, pixels[(i - 1) * 4 + 3] != 0 { source = i - 1 }
            else if x + 1 < size, pixels[(i + 1) * 4 + 3] != 0 { source = i + 1 }
            else if y > 0, pixels[(i - size) * 4 + 3] != 0 { source = i - size }
            else if y + 1 < size, pixels[(i + size) * 4 + 3] != 0 { source = i + size }
            guard source >= 0 else { continue }
            pixels[i * 4] = pixels[source * 4]
            pixels[i * 4 + 1] = pixels[source * 4 + 1]
            pixels[i * 4 + 2] = pixels[source * 4 + 2]
            pixels[i * 4 + 3] = 255
            if x > 0, pixels[(i - 1) * 4 + 3] == 0 { queue.append(Int32(i - 1)) }
            if x + 1 < size, pixels[(i + 1) * 4 + 3] == 0 { queue.append(Int32(i + 1)) }
            if y > 0, pixels[(i - size) * 4 + 3] == 0 { queue.append(Int32(i - size)) }
            if y + 1 < size, pixels[(i + size) * 4 + 3] == 0 { queue.append(Int32(i + size)) }
        }
    }

    /// Writes an RGB colour into an RGBA8 pixel buffer.
    @inline(__always)
    static func write(_ color: SIMD3<Float>, x: Int, y: Int, texSize: Int,
                      into pixels: inout [UInt8]) {
        let offset = (y * texSize + x) * 4
        pixels[offset] = UInt8(min(max(color.x, 0), 1) * 255)
        pixels[offset + 1] = UInt8(min(max(color.y, 0), 1) * 255)
        pixels[offset + 2] = UInt8(min(max(color.z, 0), 1) * 255)
        pixels[offset + 3] = 255
    }

    /// Raw-pointer overload for parallel bakes: a concurrent per-triangle pass
    /// holds the atlas as a buffer pointer rather than an `inout` array. Each
    /// triangle owns a disjoint chart, so parallel writes never touch a shared
    /// texel — safe without locking.
    static func write(_ color: SIMD3<Float>, x: Int, y: Int, texSize: Int,
                      into base: UnsafeMutablePointer<UInt8>) {
        let offset = (y * texSize + x) * 4
        base[offset] = UInt8(min(max(color.x, 0), 1) * 255)
        base[offset + 1] = UInt8(min(max(color.y, 0), 1) * 255)
        base[offset + 2] = UInt8(min(max(color.z, 0), 1) * 255)
        base[offset + 3] = 255
    }

    static func encodePNG(pixels: [UInt8], size: Int) -> Data? {
        encode(pixels: pixels, size: size, type: UTType.png, quality: nil)
    }

    /// Quality a baked atlas is JPEG-encoded at. High enough that photo-baked
    /// colour shows no visible artefact, low enough that the encoding is the
    /// point: a lossless 8192² sheet runs tens of MB, and a paged atlas
    /// multiplies that by the page count into every save and every export.
    static let atlasJPEGQuality: CGFloat = 0.92

    /// Encodes a baked colour atlas. JPEG, not PNG: the atlas is photographic
    /// (no hard-edged graphics to ring), USDZ and glTF both accept JPEG, and it
    /// shrinks the payload ~5-10× — which is what makes a multi-page atlas
    /// affordable to store and share at all. Callers that need lossless output
    /// (the Studio palette atlas, whose flat colour blocks WOULD ring) keep
    /// using `encodePNG`.
    static func encodeAtlas(pixels: [UInt8], size: Int,
                            quality: CGFloat = atlasJPEGQuality) -> Data? {
        encode(pixels: pixels, size: size, type: UTType.jpeg, quality: quality)
    }

    private static func encode(pixels: [UInt8], size: Int,
                               type: UTType, quality: CGFloat?) -> Data? {
        let bytesPerRow = size * 4
        // Encode opaque (alpha byte ignored) rather than premultiplied. Painted
        // and gutter-filled texels carry alpha 255, but the atlas background
        // (texels outside every UV chart) stays alpha 0. A PNG with that alpha
        // channel makes SceneKit / AR Quick Look treat the whole material as
        // translucent and render it in the depth-sorted transparent pass — which,
        // with the double-sided mesh material, shows up as the model going
        // half-transparent from front/back angles. The surface is never actually
        // see-through (its texels are alpha 255), so dropping alpha entirely keeps
        // the colour identical and renders the model solid everywhere.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil) else { return nil }
        let properties = quality.map {
            [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// glTF `mimeType` for an encoded atlas, sniffed from its magic bytes rather
    /// than assumed — saved models predating the JPEG switch still carry PNG
    /// pages, and an exporter that mislabels them produces a file some viewers
    /// reject outright.
    static func imageMIMEType(_ data: Data) -> String {
        data.starts(with: [0xFF, 0xD8, 0xFF]) ? "image/jpeg" : "image/png"
    }
}
