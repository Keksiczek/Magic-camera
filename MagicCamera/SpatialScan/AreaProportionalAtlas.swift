//
//  AreaProportionalAtlas.swift
//  Magic Camera
//
//  Third and final piece of variable-resolution reconstruction. The shipping
//  TextureAtlas is a UNIFORM grid — every triangle gets the same fixed-size chart —
//  so once geometry is adaptive (a wall = a few big triangles, an object = many
//  small ones) the big triangles are starved of texels and their texture goes soft.
//  That coupling is exactly what forced the earlier adaptive decimation to be
//  dropped.
//
//  This atlas instead sizes each triangle's chart by √(its area), so texels-per-
//  area — the sharpness — is roughly UNIFORM across the whole surface: a big flat
//  wall triangle gets proportionally more texels, a tiny detail triangle fewer, and
//  neither blurs. Charts are shelf-packed into a square atlas sized from the total
//  surface area (capped), and `corners(of:)` matches TextureAtlas's pixel-space
//  convention so the existing bakers / seam-leveller / gutter fill can consume it
//  unchanged when this path is wired in.
//
//  v1 scope: one square chart per triangle (the triangle occupies the lower-left
//  half; the upper-right is spare — pairing two similar-area triangles per chart is
//  the packing optimisation, later). Pure value math, off-main, unit-testable. Not
//  yet wired into the live pipeline.
//

import simd

enum AreaProportionalAtlas {
    struct Layout: AtlasLayout {
        let texSize: Int
        struct Chart { var minX: Float; var minY: Float; var side: Float; var gutter: Float }
        let charts: [Chart]

        /// Pixel-space UV corners of triangle `t` (lower-left half of its chart,
        /// inset by the gutter) — same convention as `TextureAtlas.Layout.corners`.
        func corners(of t: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
            let c = charts[t], g = c.gutter
            return (SIMD2(c.minX + g, c.minY + g),
                    SIMD2(c.minX + c.side - 2 * g, c.minY + g),
                    SIMD2(c.minX + g, c.minY + c.side - 2 * g))
        }

        var summary: String { "atlas \(texSize)² · \(charts.count) charts (area-proportional)" }
    }

    /// Shelf-pack fraction assumed when sizing the square atlas from the total chart
    /// area (square charts + gutters waste some space).
    private static let packEfficiency: Float = 0.6

    static func build(mesh: MeshData, maxTexSize: Int = 6144,
                      minChartPx: Float = 5, targetTexelsPerMetre: Float = 2200) -> Layout {
        let triCount = mesh.indices.count / 3
        guard triCount > 0 else { return Layout(texSize: 1024, charts: []) }

        // Characteristic edge ∝ √area per triangle; chart side = density·edge, so
        // chart-area / triangle-area = density² is constant → uniform texel density.
        var edge = [Float](repeating: 0, count: triCount)
        var totalArea: Float = 0
        for t in 0..<triCount {
            let a = mesh.vertices[Int(mesh.indices[t * 3])]
            let b = mesh.vertices[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.vertices[Int(mesh.indices[t * 3 + 2])]
            let area = simd_length(simd_cross(b - a, c - a)) * 0.5
            edge[t] = (2 * max(area, 0)).squareRoot()
            totalArea += area
        }

        // Density is the sharpness target, capped so it can't demand more than a
        // maxTexSize atlas (a small mesh gets a small atlas, a whole room fills it).
        let capDensity = totalArea > 1e-6
            ? Float(maxTexSize) * (packEfficiency / totalArea).squareRoot()
            : targetTexelsPerMetre
        var density = min(targetTexelsPerMetre, capDensity)

        let order = (0..<triCount).sorted { edge[$0] > edge[$1] }   // largest first
        var charts = [Layout.Chart](repeating: .init(minX: 0, minY: 0, side: 0, gutter: 0),
                                    count: triCount)
        var texSize = maxTexSize
        for _ in 0..<5 {
            var sumSq: Float = 0
            var sides = [Float](repeating: 0, count: triCount)
            for t in 0..<triCount { let s = max(edge[t] * density, minChartPx); sides[t] = s; sumSq += s * s }
            let atlasSide = min(Float(maxTexSize), (sumSq / packEfficiency).squareRoot().rounded(.up))

            // Shelf-pack largest-first into a square of side `atlasSide`.
            var x: Float = 0, y: Float = 0, rowH: Float = 0, fits = true
            for t in order {
                let s = sides[t]
                if x + s > atlasSide { x = 0; y += rowH; rowH = 0 }
                if y + s > atlasSide { fits = false; break }
                charts[t] = .init(minX: x, minY: y, side: s, gutter: max(s * 0.12, 1.5))
                x += s
                rowH = max(rowH, s)
            }
            if fits {
                texSize = min(maxTexSize, max(16, Int(atlasSide)))
                break
            }
            density *= 0.85   // packing overflowed — shrink charts and retry
        }
        return Layout(texSize: texSize, charts: charts)
    }
}
