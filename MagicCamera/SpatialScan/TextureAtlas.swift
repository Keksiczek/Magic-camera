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

enum TextureAtlas {
    /// Atlas plan: cell grid sized for the triangle count, gutters included.
    struct Layout {
        let texSize: Int
        let gridSide: Int
        let cellPx: Float
        let gutter: Float

        init(triangleCount: Int, requested: Int?) {
            gridSide = Int(ceil((Double(max(triangleCount, 1)) / 2).squareRoot()))
            texSize = requested ?? min(max(gridSide * 12, 512), 2048)
            cellPx = Float(texSize) / Float(gridSide)
            gutter = max(cellPx * 0.12, 1.5)
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
    static func buildGeometry(mesh: MeshData, layout: Layout) -> Geometry {
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

    static func encodePNG(pixels: [UInt8], size: Int) -> Data? {
        let bytesPerRow = size * 4
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
