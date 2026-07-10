//
//  ChartAtlas.swift
//  Magic Camera
//
//  True UV unwrap: contiguous multi-triangle charts instead of the per-triangle
//  quilt. Both shipping layouts give every triangle its own island, so EVERY
//  mesh edge is a texture seam — bilinear filtering falls into the gutter at
//  each edge, the seam leveler has hundreds of thousands of borders to blend,
//  and the exported atlas is unreadable/uneditable in any DCC tool.
//
//  Here edge-connected triangles whose normals agree are grown into one chart,
//  planar-projected along the chart's seed normal, and the chart rectangles are
//  shelf-packed at a uniform texel density. Inside a chart adjacent triangles
//  SHARE their UV edge (numerically identical corner coordinates), so the bake
//  is C0-continuous across them: no gutters, no bleeding, no seam to level. A
//  room becomes a handful of wall/floor charts; only the few chart borders
//  remain as (gutter-filled, seam-levelled) seams.
//
//  Safety: a chart is only grown while triangles stay within ~41° of the seed
//  normal (bounds projection distortion to ≤1.33× and forbids fold-over), and a
//  coarse height-field occupancy grid rejects a second surface layer projecting
//  onto claimed cells (stacked shelves, ramps) — a rejected triangle simply
//  seeds its own chart later. `build` returns nil when packing fails, and the
//  callers fall back to the per-triangle layouts, so this can never lose a bake.
//
//  Pure value math, off-main, unit-testable (ChartAtlasTests).
//

import simd

enum ChartAtlas {
    struct Layout: AtlasLayout {
        let texSize: Int
        let chartCount: Int
        /// Pixel-space UV corners, 3 per triangle, indexed `t*3 + corner`.
        let uvPx: [SIMD2<Float>]

        func corners(of t: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
            (uvPx[t * 3], uvPx[t * 3 + 1], uvPx[t * 3 + 2])
        }

        var summary: String { "atlas \(texSize)² · uv \(chartCount) charts" }
    }

    /// Growth gate: triangle joins a chart while its normal stays within
    /// arccos(0.75) ≈ 41° of the chart's SEED normal. Tight enough that the
    /// planar projection can't fold (needs 90°) and stays low-distortion.
    private static let normalGate: Float = 0.75
    /// Shelf packing of irregular rectangles wastes some area.
    private static let packEfficiency: Float = 0.65
    /// Pixel padding around each chart so bilinear/mip lookups at the chart
    /// border land in flood-filled gutter, never in a neighbouring chart.
    private static let chartPadPx: Float = 4

    /// Lays out `mesh` as unwrapped charts. `minTexSize` keeps a small object
    /// from baking into a tiny atlas (density is raised to fill the floor);
    /// `targetTexelsPerMetre` is the sharpness target, capped by `maxTexSize`.
    /// Returns nil for degenerate input or if packing cannot fit — callers fall
    /// back to the per-triangle layouts.
    static func build(mesh: MeshData, maxTexSize: Int = 4096,
                      minTexSize: Int = 1024,
                      targetTexelsPerMetre: Float = 2200) -> Layout? {
        let triCount = mesh.indices.count / 3
        guard triCount > 0, mesh.indices.count % 3 == 0,
              !mesh.vertices.isEmpty, maxTexSize >= 64 else { return nil }

        // 1. Weld vertices by quantised position (0.1 mm) — saved/reloaded
        //    meshes are duplicated-corner soup, and connectivity needs shared ids.
        var weldOf = [Int32](repeating: -1, count: mesh.vertices.count)
        var weldPos: [SIMD3<Float>] = []
        do {
            var byKey = [SIMD3<Int32>: Int32](minimumCapacity: mesh.vertices.count)
            for i in 0..<mesh.vertices.count {
                let v = mesh.vertices[i]
                let key = SIMD3<Int32>(Int32((v.x * 10_000).rounded()),
                                       Int32((v.y * 10_000).rounded()),
                                       Int32((v.z * 10_000).rounded()))
                if let w = byKey[key] {
                    weldOf[i] = w
                } else {
                    let w = Int32(weldPos.count)
                    byKey[key] = w
                    weldOf[i] = w
                    weldPos.append(v)
                }
            }
        }
        @inline(__always) func weldId(_ t: Int, _ corner: Int) -> Int32 {
            weldOf[Int(mesh.indices[t * 3 + corner])]
        }

        // 2. Face normals, areas, and edge adjacency over welded ids.
        var normal = [SIMD3<Float>](repeating: .zero, count: triCount)
        var totalArea: Float = 0
        var neighbors = [[Int32]](repeating: [], count: triCount)
        do {
            var edgeFirst = [UInt64: Int32](minimumCapacity: triCount * 2)
            for t in 0..<triCount {
                let a = weldId(t, 0), b = weldId(t, 1), c = weldId(t, 2)
                guard a != b, b != c, a != c else { continue }   // degenerate
                let cross = simd_cross(weldPos[Int(b)] - weldPos[Int(a)],
                                       weldPos[Int(c)] - weldPos[Int(a)])
                let len = simd_length(cross)
                guard len > 1e-12 else { continue }
                normal[t] = cross / len
                totalArea += len * 0.5
                for (u, v) in [(a, b), (b, c), (c, a)] {
                    let lo = UInt64(UInt32(bitPattern: min(u, v)))
                    let hi = UInt64(UInt32(bitPattern: max(u, v)))
                    let key = (hi << 32) | lo
                    if let other = edgeFirst[key] {
                        if other >= 0 {
                            neighbors[t].append(other)
                            neighbors[Int(other)].append(Int32(t))
                            edgeFirst[key] = -1   // non-manifold third+ tri: no link
                        }
                    } else {
                        edgeFirst[key] = Int32(t)
                    }
                }
            }
        }
        guard totalArea > 1e-8 else { return nil }
        let meanEdge = (2 * totalArea / Float(triCount)).squareRoot()

        // 3. Grow charts. BFS over edge adjacency, gated by the seed normal and
        //    a height-field occupancy grid (in the chart's projection plane) so
        //    a second geometric layer can't project onto claimed texels.
        struct Chart {
            var tris: [Int32] = []
            var u = SIMD3<Float>.zero
            var v = SIMD3<Float>.zero
            var minP = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
            var maxP = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        }
        var chartOf = [Int32](repeating: -1, count: triCount)
        var charts: [Chart] = []
        // Per-weld-id projection cache, stamped by chart index.
        var projStamp = [Int32](repeating: -1, count: weldPos.count)
        var projVal = [SIMD2<Float>](repeating: .zero, count: weldPos.count)
        let occCell = max(meanEdge * 2, 0.02)
        let occTol = max(occCell, 0.15)

        for seed in 0..<triCount where chartOf[seed] == -1 {
            let n = normal[seed]
            guard simd_length_squared(n) > 0.5 else { continue }   // degenerate tri
            let chartIndex = Int32(charts.count)
            var chart = Chart()
            // Stable in-plane basis from the seed normal.
            let helper = abs(n.x) < 0.8 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            chart.u = simd_normalize(simd_cross(n, helper))
            chart.v = simd_cross(n, chart.u)
            var occupancy = [SIMD2<Int32>: Float]()

            @inline(__always) func project(_ w: Int32) -> SIMD2<Float> {
                if projStamp[Int(w)] != chartIndex {
                    let p = weldPos[Int(w)]
                    projVal[Int(w)] = SIMD2(simd_dot(p, chart.u), simd_dot(p, chart.v))
                    projStamp[Int(w)] = chartIndex
                }
                return projVal[Int(w)]
            }

            var queue: [Int32] = [Int32(seed)]
            var visited: Set<Int32> = [Int32(seed)]
            var head = 0
            while head < queue.count {
                let t = Int(queue[head]); head += 1
                guard chartOf[t] == -1, simd_dot(normal[t], n) >= Self.normalGate
                else { continue }
                // Layer check: each corner's cell must be free, or claimed at a
                // compatible height along the seed normal.
                var corners: [(cell: SIMD2<Int32>, h: Float, p: SIMD2<Float>)] = []
                corners.reserveCapacity(3)
                var layered = false
                for k in 0..<3 {
                    let w = weldId(t, k)
                    let p = project(w)
                    let cell = SIMD2<Int32>(Int32((p.x / occCell).rounded(.down)),
                                            Int32((p.y / occCell).rounded(.down)))
                    let h = simd_dot(weldPos[Int(w)], n)
                    if let existing = occupancy[cell], abs(existing - h) > occTol {
                        layered = true
                        break
                    }
                    corners.append((cell, h, p))
                }
                if layered { continue }   // another layer — it seeds its own chart
                chartOf[t] = chartIndex
                chart.tris.append(Int32(t))
                for c in corners {
                    if occupancy[c.cell] == nil { occupancy[c.cell] = c.h }
                    chart.minP = simd_min(chart.minP, c.p)
                    chart.maxP = simd_max(chart.maxP, c.p)
                }
                for nb in neighbors[t] where !visited.contains(nb) {
                    visited.insert(nb)
                    queue.append(nb)
                }
            }
            if !chart.tris.isEmpty { charts.append(chart) }
        }
        guard !charts.isEmpty else { return nil }

        // 4. Pack chart rectangles at a uniform texel density (texels/metre) —
        //    shelf packing, tallest first, shrinking density until it fits.
        let capDensity = Float(maxTexSize) * (Self.packEfficiency / totalArea).squareRoot()
        var density = min(targetTexelsPerMetre, capDensity)
        // A small subject would land under the atlas floor — raise density so it
        // fills `minTexSize` instead of baking soft.
        if density * (totalArea / Self.packEfficiency).squareRoot() < Float(minTexSize) {
            density = Float(minTexSize) * (Self.packEfficiency / totalArea).squareRoot()
            density = min(density, capDensity)
        }

        struct Placed { var origin = SIMD2<Float>.zero; var rotated = false }
        var placed = [Placed](repeating: Placed(), count: charts.count)
        let pad = Self.chartPadPx
        var texSize = maxTexSize
        var fitted = false
        // Two nested searches: the atlas side may need to GROW past the area
        // estimate (shelf packing of few large charts wastes more than the
        // efficiency guess — and that waste is scale-invariant, so shrinking
        // density alone can never converge); only once the side is pinned at
        // `maxTexSize` does shrinking density help.
        densityLoop: for _ in 0..<8 {
            var widths = [Float](repeating: 0, count: charts.count)
            var heights = [Float](repeating: 0, count: charts.count)
            var areaSum: Float = 0
            var maxDim: Float = 0
            for (i, chart) in charts.enumerated() {
                let ext = simd_max(chart.maxP - chart.minP, SIMD2<Float>.zero)
                var w = ext.x * density + 2 * pad
                var h = ext.y * density + 2 * pad
                if w < h { swap(&w, &h); placed[i].rotated = true } else { placed[i].rotated = false }
                widths[i] = w; heights[i] = h
                areaSum += w * h
                maxDim = max(maxDim, w)
            }
            if maxDim > Float(maxTexSize) { density *= 0.85; continue }
            let order = charts.indices.sorted { heights[$0] > heights[$1] }
            var side = min(Float(maxTexSize),
                           max(Float(minTexSize), maxDim,
                               (areaSum / Self.packEfficiency).squareRoot().rounded(.up)))
            for _ in 0..<6 {
                var x: Float = 0, y: Float = 0, rowH: Float = 0
                for i in order {
                    if x + widths[i] > side { x = 0; y += rowH; rowH = 0 }
                    placed[i].origin = SIMD2(x, y)
                    x += widths[i]
                    rowH = max(rowH, heights[i])
                }
                let usedHeight = y + rowH
                if usedHeight <= side {
                    texSize = Int(side.rounded(.up))
                    fitted = true
                    break densityLoop
                }
                if side >= Float(maxTexSize) { break }   // can't grow — shrink density
                side = min(Float(maxTexSize), max(side * 1.25, usedHeight.rounded(.up)))
            }
            density *= 0.85
        }
        guard fitted, density > 1 else { return nil }

        // 5. Emit pixel-space corners. Shared welded vertices inside a chart get
        //    numerically identical coordinates — that is the seamlessness.
        var uvPx = [SIMD2<Float>](repeating: SIMD2(1, 1), count: triCount * 3)
        for (ci, chart) in charts.enumerated() {
            let p = placed[ci]
            for t32 in chart.tris {
                let t = Int(t32)
                for k in 0..<3 {
                    let w = Int(weldId(t, k))
                    let pos = weldPos[w]
                    let proj = SIMD2(simd_dot(pos, chart.u), simd_dot(pos, chart.v))
                    var local = (proj - chart.minP) * density
                    if p.rotated { local = SIMD2(local.y, local.x) }
                    uvPx[t * 3 + k] = p.origin + SIMD2(pad, pad) + local
                }
            }
        }
        return Layout(texSize: texSize, chartCount: charts.count, uvPx: uvPx)
    }
}
