//
//  TextureSeamLeveler.swift
//  Magic Camera
//
//  Gradient-domain seam levelling for the per-triangle photo atlas — the fix for
//  the colour seams where adjacent triangles were baked from different keyframes
//  (different exposure / view-dependent shading), so the model reads as a mosaic
//  rather than one continuous surface.
//
//  Lempitsky–Ivanov in spirit: sample each triangle corner's baked colour from
//  the atlas, then solve a per-corner additive correction `g` that
//    • makes co-located corners (the split copies of a shared 3-D vertex) agree
//      on a colour — so the surface becomes C0-continuous and seams vanish,
//    • stays smooth within each triangle and minimal in magnitude — so it only
//      absorbs the seam jump and preserves the original detail,
//  via Gauss–Seidel relaxation, then re-applies it barycentrically to the atlas.
//
//  It runs on the finished atlas, so it's independent of whether the bake ran on
//  the GPU or the CPU. Pure value math, off-main-thread friendly.
//

import simd

enum TextureSeamLeveler {
    /// Levels cross-view colour seams in `pixels` (RGBA8, `size`×`size`) in place.
    /// `geometry` carries the duplicated-corner vertices; `layout` maps each
    /// triangle to its atlas chart. A no-op (cheap) when the bake was already
    /// seamless — the solved correction is then ~zero.
    ///
    /// `page` selects which sheet of a multi-page layout is being levelled, and
    /// `layout` must be the FULL layout (not an `AtlasPage` wrapper): this pass
    /// *samples* the corners it is handed, so an off-canvas chart would read the
    /// page's origin texel as though it were the triangle's baked colour. Pass
    /// the base layout and let the filter below drop the off-page triangles from
    /// the solve entirely. Seams between triangles on DIFFERENT pages are left
    /// alone — the two sides live in separate images, so there is no single
    /// buffer to blend them in; those borders are chart borders, already gutter
    /// -filled, and the multi-view bake normalises every view to the cloud
    /// albedo, so the jump they would carry is small.
    static func level(pixels: inout [UInt8], size: Int,
                      geometry: TextureAtlas.Geometry, layout: some AtlasLayout,
                      page: Int = 0) {
        let verts = geometry.mesh.vertices
        let allTriangles = verts.count / 3
        // Triangles this page actually owns. Single-page layouts map to
        // themselves, so the solve below is identical to the unpaged one.
        let tris: [Int] = layout.pageCount <= 1
            ? Array(0..<allTriangles)
            : (0..<allTriangles).filter { layout.page(of: $0) == page }
        let triCount = tris.count
        // Bounded: skip a degenerate mesh or one so large the relaxation would
        // dominate the bake. 600 k (was 200 k): today's room meshes run
        // 380-500 k triangles, so the cap was silently skipping seam levelling
        // on exactly the scans with the most seams — with the UV unwrap that
        // left every chart border unblended (part of the mosaic look). The
        // iteration tier below keeps the big-mesh cost bounded instead.
        guard triCount >= 2, triCount <= 600_000,
              pixels.count == size * size * 4 else { return }

        // 1. Sample each corner's baked colour, inset toward the triangle centre
        //    so we read painted interior rather than a gutter texel.
        var f = [SIMD3<Float>](repeating: .zero, count: triCount * 3)
        for (i, t) in tris.enumerated() {
            let c = layout.corners(of: t)
            let centre = (c.0 + c.1 + c.2) / 3
            let cs = (c.0, c.1, c.2)
            f[i * 3]     = sample(pixels, size, cs.0 * 0.75 + centre * 0.25)
            f[i * 3 + 1] = sample(pixels, size, cs.1 * 0.75 + centre * 0.25)
            f[i * 3 + 2] = sample(pixels, size, cs.2 * 0.75 + centre * 0.25)
        }

        // 2. Weld corners by world position → sites (the split copies of a shared
        //    3-D vertex). 1 mm quantisation matches the recorder's voxel scale.
        var siteOf = [Int](repeating: -1, count: triCount * 3)
        var sites: [[Int]] = []
        var byKey = [SIMD3<Int32>: Int](minimumCapacity: triCount)
        for i in 0..<(triCount * 3) {
            let v = verts[tris[i / 3] * 3 + i % 3]
            let key = SIMD3<Int32>(Int32((v.x * 1000).rounded()),
                                   Int32((v.y * 1000).rounded()),
                                   Int32((v.z * 1000).rounded()))
            if let s = byKey[key] { siteOf[i] = s; sites[s].append(i) }
            else { let s = sites.count; byKey[key] = s; siteOf[i] = s; sites.append([i]) }
        }

        // 3. Gauss–Seidel. Each correction is pulled toward (a) agreement with its
        //    co-located corners [seam], (b) its triangle's other corners [smooth],
        //    and (c) zero [minimal correction → keep detail]. Re-centred after.
        var g = [SIMD3<Float>](repeating: .zero, count: triCount * 3)
        let wSeam: Float = 1.0, wSmooth: Float = 0.25, wReg: Float = 0.05
        let iterations = triCount > 200_000 ? 40 : (triCount > 60_000 ? 80 : 160)
        for _ in 0..<iterations {
            for t in 0..<triCount {
                let base = t * 3
                for k in 0..<3 {
                    let c = base + k
                    var seamAccum = SIMD3<Float>.zero
                    var seamW: Float = 0
                    for a in sites[siteOf[c]] where a != c {
                        seamAccum += g[a] + f[a] - f[c]
                        seamW += 1
                    }
                    var smoothAccum = SIMD3<Float>.zero
                    for j in 0..<3 where j != k { smoothAccum += g[base + j] }
                    let denom = wSeam * seamW + wSmooth * 2 + wReg
                    g[c] = (wSeam * seamAccum + wSmooth * smoothAccum) / denom
                }
            }
        }
        // Re-centre so the overall tone is preserved — only the seam jumps move.
        var mean = SIMD3<Float>.zero
        for x in g { mean += x }
        mean /= Float(g.count)
        for i in 0..<g.count { g[i] -= mean }

        // 4. Apply: add the barycentric-interpolated correction to each chart.
        //    Each texel is claimed once — in a UV-unwrapped atlas adjacent
        //    triangles share their edge texels, and adding both corrections
        //    would double the delta along every interior edge.
        var claimed = TexelClaimMask(texelCount: size * size)
        for (i, t) in tris.enumerated() {
            let g0 = g[i * 3], g1 = g[i * 3 + 1], g2 = g[i * 3 + 2]
            TextureAtlas.forEachTexel(corners: layout.corners(of: t), texSize: size) { px, py, l0, l1, l2 in
                guard claimed.claim(py * size + px) else { return }
                add(&pixels, size, x: px, y: py, delta: g0 * l0 + g1 * l1 + g2 * l2)
            }
        }
    }

    /// Nearest-texel RGB sample in [0,1], clamped to the atlas.
    @inline(__always)
    private static func sample(_ pixels: [UInt8], _ size: Int, _ uv: SIMD2<Float>) -> SIMD3<Float> {
        let x = min(max(Int(uv.x), 0), size - 1)
        let y = min(max(Int(uv.y), 0), size - 1)
        let o = (y * size + x) * 4
        return SIMD3<Float>(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2])) / 255
    }

    @inline(__always)
    private static func add(_ pixels: inout [UInt8], _ size: Int, x: Int, y: Int, delta: SIMD3<Float>) {
        let o = (y * size + x) * 4
        pixels[o]     = UInt8(min(max((Float(pixels[o])     / 255 + delta.x) * 255, 0), 255))
        pixels[o + 1] = UInt8(min(max((Float(pixels[o + 1]) / 255 + delta.y) * 255, 0), 255))
        pixels[o + 2] = UInt8(min(max((Float(pixels[o + 2]) / 255 + delta.z) * 255, 0), 255))
    }
}
