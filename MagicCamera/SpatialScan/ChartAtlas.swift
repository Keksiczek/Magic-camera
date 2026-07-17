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
//  The growth GATE is searched, not fixed. A tight gate keeps projection
//  distortion low but shatters a real scan: marching-cubes normals scatter so
//  hard (22-27% of edges exceed 41° dihedral on every device mesh) that a face
//  rejected by the seed gate becomes an isolated island — its neighbours are
//  already claimed, so it seeds a 1-2 triangle chart of its own. Measured on
//  real exports that costs ~5.5 tris/chart and tens of thousands of islands,
//  and the per-chart padding then eats the texel density the atlas could have
//  spent on the surface. Loosening the gate recovers that density but squashes
//  grazing triangles, so neither end wins everywhere: an object's density is
//  already at target (bigger charts buy nothing, distortion is pure loss) while
//  a room is area-limited (the padding matters more than the squash). `build`
//  therefore packs each candidate gate and keeps the one with the best MEASURED
//  effective density — no constant tuned against one mesh.
//
//  Safety: the gate never exceeds 84°, so the planar projection can't fold
//  (needs 90°), and a coarse height-field occupancy grid rejects a second
//  surface layer projecting onto claimed cells (stacked shelves, ramps) — a
//  rejected triangle simply seeds its own chart later. `build` returns nil when
//  packing fails, and the callers fall back to the per-triangle layouts, so
//  this can never lose a bake.
//
//  Pure value math, off-main, unit-testable (ChartAtlasTests).
//

import simd

enum ChartAtlas {
    struct Layout: AtlasLayout {
        let texSize: Int
        let pageCount: Int
        let chartCount: Int
        /// Growth gate the search settled on — telemetry, so a device round can
        /// tell a shattered layout from a loosened one.
        let gate: Float
        /// Texels per metre the packing converged on — the number that decides
        /// sharpness, and the one to watch when tuning pages.
        let density: Float
        /// Pixel-space UV corners, 3 per triangle, indexed `t*3 + corner`.
        let uvPx: [SIMD2<Float>]
        /// Page each triangle's chart landed on. Empty for a single-page layout.
        let pageOfTri: [UInt8]

        func corners(of t: Int) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
            (uvPx[t * 3], uvPx[t * 3 + 1], uvPx[t * 3 + 2])
        }

        func page(of t: Int) -> Int {
            pageOfTri.isEmpty ? 0 : Int(pageOfTri[t])
        }

        var summary: String {
            "atlas \(texSize)²\(pageCount > 1 ? " ×\(pageCount)" : "") · uv \(chartCount) charts"
        }
    }

    /// Candidate growth gates, TIGHTEST FIRST so a tie keeps the least-distorted
    /// layout. A triangle joins a chart while its normal stays within
    /// arccos(gate) of the chart's seed normal: 0.75 ≈ 41°, 0.1 ≈ 84°. Nothing
    /// here reaches 90°, so no candidate can fold the projection.
    private static let gateCandidates: [Float] = [0.75, 0.5, 0.25, 0.1]
    /// Shelf packing of irregular rectangles wastes some area.
    private static let packEfficiency: Float = 0.65
    /// Pixel padding around each chart so bilinear/mip lookups at the chart
    /// border land in flood-filled gutter, never in a neighbouring chart.
    private static let chartPadPx: Float = 4

    private struct Chart {
        var tris: [Int32] = []
        var seed = SIMD3<Float>.zero
        var u = SIMD3<Float>.zero
        var v = SIMD3<Float>.zero
        var minP = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxP = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
    }

    /// Welded mesh + topology, reused across every candidate gate (the weld and
    /// the adjacency are gate-independent and are the expensive part).
    private struct Unwrapper {
        var pos: [SIMD3<Float>] = []
        var tri: [SIMD3<Int32>] = []          // welded corners, per INPUT triangle
        var normal: [SIMD3<Float>] = []
        var area: [Float] = []
        var neighbors: [[Int32]] = []
        var totalArea: Float = 0
        var occCell: Float = 0
        var occTol: Float = 0
        // Scratch, stamped so it never needs clearing between charts or gates.
        var projStamp: [Int32] = []
        var projVal: [SIMD2<Float>] = []
        var visitStamp: [Int32] = []
        var stamp: Int32 = 0

        mutating func growCharts(gate: Float) -> [Chart] {
            let triCount = tri.count
            var chartOf = [Int32](repeating: -1, count: triCount)
            var charts: [Chart] = []

            for seed in 0..<triCount where chartOf[seed] == -1 {
                let n = normal[seed]
                guard simd_length_squared(n) > 0.5 else { continue }   // degenerate tri
                stamp += 1
                let mark = stamp
                let chartIndex = Int32(charts.count)
                var chart = Chart()
                chart.seed = n
                // Stable in-plane basis from the seed normal.
                let helper = abs(n.x) < 0.8 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
                chart.u = simd_normalize(simd_cross(n, helper))
                chart.v = simd_cross(n, chart.u)
                var occupancy = [SIMD2<Int32>: Float]()

                var queue: [Int32] = [Int32(seed)]
                visitStamp[seed] = mark
                var head = 0
                while head < queue.count {
                    let t = Int(queue[head]); head += 1
                    guard chartOf[t] == -1, simd_dot(normal[t], n) >= gate else { continue }
                    // Layer check: each corner's cell must be free, or claimed at
                    // a compatible height along the seed normal.
                    var corners: [(cell: SIMD2<Int32>, h: Float, p: SIMD2<Float>)] = []
                    corners.reserveCapacity(3)
                    var layered = false
                    for k in 0..<3 {
                        let w = tri[t][k]
                        if projStamp[Int(w)] != mark {
                            let q = pos[Int(w)]
                            projVal[Int(w)] = SIMD2(simd_dot(q, chart.u), simd_dot(q, chart.v))
                            projStamp[Int(w)] = mark
                        }
                        let p = projVal[Int(w)]
                        let cell = SIMD2<Int32>(Int32((p.x / occCell).rounded(.down)),
                                                Int32((p.y / occCell).rounded(.down)))
                        let h = simd_dot(pos[Int(w)], n)
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
                    for nb in neighbors[t] where visitStamp[Int(nb)] != mark {
                        visitStamp[Int(nb)] = mark
                        queue.append(nb)
                    }
                }
                if !chart.tris.isEmpty { charts.append(chart) }
            }
            return charts
        }

        /// Area-weighted mean of cos(angle between a triangle's normal and its
        /// chart's projection direction). A triangle at angle θ projects to cosθ
        /// of its area, so it receives cosθ of the texels its surface deserves —
        /// this is what a loose gate spends to buy bigger charts.
        func meanProjectionCosine(_ charts: [Chart]) -> Float {
            var total: Float = 0, weighted: Float = 0
            for chart in charts {
                for t in chart.tris {
                    let a = area[Int(t)]
                    total += a
                    weighted += a * max(0, simd_dot(normal[Int(t)], chart.seed))
                }
            }
            return total > 0 ? weighted / total : 0
        }
    }

    private struct Packing {
        var origins: [SIMD2<Float>] = []
        var rotated: [Bool] = []
        var pages: [UInt8] = []
        var pageCount = 1
        var texSize = 0
        var density: Float = 0
    }

    /// Lays out `mesh` as unwrapped charts. `minTexSize` keeps a small object
    /// from baking into a tiny atlas (density is raised to fill the floor);
    /// `targetTexelsPerMetre` is the sharpness target, capped by `maxTexSize`.
    /// Returns nil for degenerate input or if packing cannot fit — callers fall
    /// back to the per-triangle layouts.
    /// `maxPages` raises the texel ceiling for a surface too large to reach the
    /// target density in one sheet: the bound is `maxTexSize · √(0.65·pages/area)`,
    /// so N pages buy √N. Costs N× the texture memory, which the bake spends one
    /// page at a time. Default 1 — callers opt in.
    static func build(mesh: MeshData, maxTexSize: Int = 4096,
                      minTexSize: Int = 1024,
                      targetTexelsPerMetre: Float = 2200,
                      maxPages: Int = 1) -> Layout? {
        let triCount = mesh.indices.count / 3
        guard triCount > 0, mesh.indices.count % 3 == 0,
              !mesh.vertices.isEmpty, maxTexSize >= 64 else { return nil }

        // 1. Weld vertices by quantised position (0.1 mm) — saved/reloaded
        //    meshes are duplicated-corner soup, and connectivity needs shared ids.
        var weldOf = [Int32](repeating: -1, count: mesh.vertices.count)
        var u = Unwrapper()
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
                    let w = Int32(u.pos.count)
                    byKey[key] = w
                    weldOf[i] = w
                    u.pos.append(v)
                }
            }
        }

        // 2. Face normals, areas, and edge adjacency over welded ids.
        u.tri = .init(repeating: .init(repeating: -1), count: triCount)
        u.normal = .init(repeating: .zero, count: triCount)
        u.area = .init(repeating: 0, count: triCount)
        u.neighbors = .init(repeating: [], count: triCount)
        do {
            var edgeFirst = [UInt64: Int32](minimumCapacity: triCount * 2)
            for t in 0..<triCount {
                let a = weldOf[Int(mesh.indices[t * 3])]
                let b = weldOf[Int(mesh.indices[t * 3 + 1])]
                let c = weldOf[Int(mesh.indices[t * 3 + 2])]
                u.tri[t] = SIMD3(a, b, c)
                guard a != b, b != c, a != c else { continue }   // degenerate
                let cross = simd_cross(u.pos[Int(b)] - u.pos[Int(a)],
                                       u.pos[Int(c)] - u.pos[Int(a)])
                let len = simd_length(cross)
                guard len > 1e-12 else { continue }
                u.normal[t] = cross / len
                u.area[t] = len * 0.5
                u.totalArea += len * 0.5
                for (p, q) in [(a, b), (b, c), (c, a)] {
                    let lo = UInt64(UInt32(bitPattern: min(p, q)))
                    let hi = UInt64(UInt32(bitPattern: max(p, q)))
                    let key = (hi << 32) | lo
                    if let other = edgeFirst[key] {
                        if other >= 0 {
                            u.neighbors[t].append(other)
                            u.neighbors[Int(other)].append(Int32(t))
                            edgeFirst[key] = -1   // non-manifold third+ tri: no link
                        }
                    } else {
                        edgeFirst[key] = Int32(t)
                    }
                }
            }
        }
        guard u.totalArea > 1e-8 else { return nil }
        let meanEdge = (2 * u.totalArea / Float(triCount)).squareRoot()
        u.occCell = max(meanEdge * 2, 0.02)
        u.occTol = max(u.occCell, 0.15)
        u.projStamp = .init(repeating: -1, count: u.pos.count)
        u.projVal = .init(repeating: .zero, count: u.pos.count)
        u.visitStamp = .init(repeating: -1, count: triCount)

        // 3. Search the gate. Loosening it can only raise density while the atlas
        //    is AREA-limited; once density is already at target (a small object)
        //    bigger charts buy nothing and the extra distortion is pure loss, so
        //    skip the search entirely and keep the tightest gate.
        let pages = pageBudget(totalArea: u.totalArea, maxTexSize: maxTexSize,
                               maxPages: maxPages, targetTexelsPerMetre: targetTexelsPerMetre)
        let capDensity = Float(maxTexSize)
            * (Self.packEfficiency * Float(pages) / u.totalArea).squareRoot()
        let candidates = capDensity < targetTexelsPerMetre ? Self.gateCandidates
                                                           : [Self.gateCandidates[0]]
        var best: (charts: [Chart], packing: Packing, gate: Float, score: Float)?
        for gate in candidates {
            let charts = u.growCharts(gate: gate)
            guard !charts.isEmpty,
                  let packing = pack(charts, totalArea: u.totalArea, maxTexSize: maxTexSize,
                                     minTexSize: minTexSize,
                                     targetTexelsPerMetre: targetTexelsPerMetre,
                                     maxPages: maxPages)
            else { continue }
            // Effective linear texel density on the SURFACE: a triangle at angle θ
            // receives density²·cosθ texels per m², so density·√cosθ is what the
            // eye actually gets. Strict `>` keeps the tightest gate on a tie.
            let score = packing.density * u.meanProjectionCosine(charts).squareRoot()
            if best == nil || score > best!.score {
                best = (charts, packing, gate, score)
            }
        }
        guard let winner = best else { return nil }

        // 4. Emit pixel-space corners. Shared welded vertices inside a chart get
        //    numerically identical coordinates — that is the seamlessness.
        var uvPx = [SIMD2<Float>](repeating: SIMD2(1, 1), count: triCount * 3)
        let multiPage = winner.packing.pageCount > 1
        var pageOfTri = multiPage ? [UInt8](repeating: 0, count: triCount) : []
        let pad = Self.chartPadPx
        for (ci, chart) in winner.charts.enumerated() {
            let origin = winner.packing.origins[ci]
            let rotated = winner.packing.rotated[ci]
            let page = winner.packing.pages[ci]
            for t32 in chart.tris {
                let t = Int(t32)
                if multiPage { pageOfTri[t] = page }
                for k in 0..<3 {
                    let pos = u.pos[Int(u.tri[t][k])]
                    let proj = SIMD2(simd_dot(pos, chart.u), simd_dot(pos, chart.v))
                    var local = (proj - chart.minP) * winner.packing.density
                    if rotated { local = SIMD2(local.y, local.x) }
                    uvPx[t * 3 + k] = origin + SIMD2(pad, pad) + local
                }
            }
        }
        return Layout(texSize: winner.packing.texSize, pageCount: winner.packing.pageCount,
                      chartCount: winner.charts.count, gate: winner.gate,
                      density: winner.packing.density, uvPx: uvPx, pageOfTri: pageOfTri)
    }

    /// How many pages to actually spend. `maxPages` is a CEILING, not a quota:
    /// only a surface too large to reach `targetTexelsPerMetre` in one sheet has
    /// any use for a second. Handing a small subject more would let the
    /// minTexSize floor inflate its density far past anything the keyframes
    /// carry — 0.11 m² over 4 pages asked for 4874 texels/m and burned 3 sheets.
    private static func pageBudget(totalArea: Float, maxTexSize: Int, maxPages: Int,
                                   targetTexelsPerMetre: Float) -> Int {
        let perPage = Self.packEfficiency * Float(maxTexSize) * Float(maxTexSize)
        let needed = totalArea * targetTexelsPerMetre * targetTexelsPerMetre / perPage
        return max(1, min(max(1, maxPages), Int(needed.rounded(.up))))
    }

    /// Packs chart rectangles at a uniform texel density (texels/metre) — shelf
    /// packing, tallest first, spilling onto the next page when a shelf runs off
    /// the sheet, and shrinking density until everything fits within `maxPages`.
    /// Returns nil if it cannot converge.
    ///
    /// `maxPages == 1` reduces exactly to the single-sheet packing: the rows
    /// stack, nothing spills, and the grow rule below is the same one.
    private static func pack(_ charts: [Chart], totalArea: Float, maxTexSize: Int,
                             minTexSize: Int, targetTexelsPerMetre: Float,
                             maxPages: Int) -> Packing? {
        let pages = pageBudget(totalArea: totalArea, maxTexSize: maxTexSize,
                               maxPages: maxPages, targetTexelsPerMetre: targetTexelsPerMetre)
        let budget = Self.packEfficiency * Float(pages)
        let capDensity = Float(maxTexSize) * (budget / totalArea).squareRoot()
        var density = min(targetTexelsPerMetre, capDensity)
        // A small subject would land under the atlas floor — raise density so it
        // fills `minTexSize` instead of baking soft.
        if density * (totalArea / budget).squareRoot() < Float(minTexSize) {
            density = Float(minTexSize) * (budget / totalArea).squareRoot()
            density = min(density, capDensity)
        }

        var result = Packing()
        result.origins = .init(repeating: .zero, count: charts.count)
        result.rotated = .init(repeating: false, count: charts.count)
        result.pages = .init(repeating: 0, count: charts.count)
        let pad = Self.chartPadPx
        // Two nested searches: the atlas side may need to GROW past the area
        // estimate (shelf packing of few large charts wastes more than the
        // efficiency guess — and that waste is scale-invariant, so shrinking
        // density alone can never converge); only once the side is pinned at
        // `maxTexSize` does shrinking density help.
        for _ in 0..<8 {
            var widths = [Float](repeating: 0, count: charts.count)
            var heights = [Float](repeating: 0, count: charts.count)
            var areaSum: Float = 0
            var maxDim: Float = 0
            for (i, chart) in charts.enumerated() {
                let ext = simd_max(chart.maxP - chart.minP, SIMD2<Float>.zero)
                var w = ext.x * density + 2 * pad
                var h = ext.y * density + 2 * pad
                if w < h { swap(&w, &h); result.rotated[i] = true } else { result.rotated[i] = false }
                widths[i] = w; heights[i] = h
                areaSum += w * h
                maxDim = max(maxDim, w)
            }
            if maxDim > Float(maxTexSize) { density *= 0.85; continue }
            let order = charts.indices.sorted { heights[$0] > heights[$1] }
            var side = min(Float(maxTexSize),
                           max(Float(minTexSize), maxDim,
                               (areaSum / budget).squareRoot().rounded(.up)))
            for _ in 0..<6 {
                // Shelve into rows of width `side`, then lay the rows onto pages.
                var rows: [[Int]] = []
                var rowHeights: [Float] = []
                var current: [Int] = []
                var x: Float = 0, rowH: Float = 0
                for i in order {
                    if !current.isEmpty, x + widths[i] > side {
                        rows.append(current); rowHeights.append(rowH)
                        current = []; x = 0; rowH = 0
                    }
                    current.append(i)
                    x += widths[i]
                    rowH = max(rowH, heights[i])
                }
                if !current.isEmpty { rows.append(current); rowHeights.append(rowH) }

                var page = 0
                var y: Float = 0
                for (r, h) in rowHeights.enumerated() {
                    if y + h > side, y > 0 { page += 1; y = 0 }   // spill to next page
                    var cursor: Float = 0
                    for i in rows[r] {
                        result.origins[i] = SIMD2(cursor, y)
                        result.pages[i] = UInt8(min(page, Int(UInt8.max)))
                        cursor += widths[i]
                    }
                    y += h
                }
                if page < pages {
                    result.texSize = Int(side.rounded(.up))
                    result.density = density
                    result.pageCount = page + 1
                    return density > 1 ? result : nil
                }
                if side >= Float(maxTexSize) { break }   // can't grow — shrink density
                // Same rule as the single-sheet case, spread over the page budget.
                let needed = (rowHeights.reduce(0, +) / Float(pages)).rounded(.up)
                side = min(Float(maxTexSize), max(side * 1.25, needed))
            }
            density *= 0.85
        }
        return nil
    }
}
