//
//  OccupancyGrid.swift
//  Magic Camera
//
//  Bird's-eye density map — the one part of RoomPlan that is not a neural net.
//  Points are projected onto the ground plane into a fixed grid (≈3 cm in XZ,
//  30 cm height slices); each column keeps its point count and which height
//  slices it occupies. Walls then fall out of a threshold: a column that is
//  dense *and* spans most of the room's height is a vertical ridge, and a run of
//  such columns in a line is a wall.
//
//  It earns its place because it beats what came before on its own terms:
//  review-time wall flattening was seeded only by ARKit plane anchors, so a
//  point scan captured without them left the regulariser guessing from random
//  RANSAC triples; and `FloorPlanBuilder` needed a *classified* mesh, so those
//  same scans got no floor plan at all. Both now have a geometric fallback.
//
//  Pure value math (no ARKit, no RNG — deterministic and unit-testable).
//  See docs/analysis/APPLE-PIPELINE-NOTES.md, item 4.
//

import simd

struct OccupancyGrid {

    // MARK: - Tuning

    /// Ground-plane resolution. 3 cm is fine enough to separate a wall from the
    /// furniture against it, coarse enough that a whole room fits the cap.
    static let defaultCellSize: Float = 0.03
    /// Height band per slice. A wall crosses most bands; a table crosses one.
    static let defaultSliceHeight: Float = 0.30
    /// Grid side cap. 512² columns ≈ 15 m across at 3 cm — past that the cell
    /// grows instead, so cost stays bounded no matter how big the scan is.
    static let maxDimension = 512
    /// Height slices are a `UInt32` bitmask, so at most 32 of them.
    static let maxSlices = 32

    // MARK: - Geometry

    let cellSize: Float
    let sliceHeight: Float
    let columns: Int                    // cells along +X
    let rows: Int                       // cells along +Z
    /// World (x, z) of column (0, 0)'s min corner.
    let origin: SIMD2<Float>
    /// World Y of slice 0's floor.
    let floorY: Float
    let sliceCount: Int
    /// Points per column, `columns * rows`, row-major in Z.
    let counts: [Int32]
    /// Bit `i` set = the column has at least one point in height slice `i`.
    let slices: [UInt32]

    // MARK: - Build

    /// Projects `positions` into a grid, or `nil` when there is nothing to
    /// project. `cellSize` is a floor, not a promise: a scan wider than
    /// `maxDimension` cells gets a proportionally larger cell.
    static func build(from positions: [SIMD3<Float>],
                      cellSize requestedCell: Float = defaultCellSize,
                      sliceHeight requestedSlice: Float = defaultSliceHeight,
                      maxDimension: Int = maxDimension) -> OccupancyGrid? {
        guard !positions.isEmpty, requestedCell > 0, requestedSlice > 0,
              maxDimension > 0 else { return nil }

        var lo = positions[0], hi = positions[0]
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let extentX = Swift.max(hi.x - lo.x, requestedCell)
        let extentZ = Swift.max(hi.z - lo.z, requestedCell)
        let extentY = Swift.max(hi.y - lo.y, requestedSlice)

        let cell = Swift.max(requestedCell,
                             Swift.max(extentX, extentZ) / Float(maxDimension))
        // `+ 1`, not `.rounded(.up)`: a point exactly on the far edge divides to
        // the column *past* the last one. Rounding up covers it only when the
        // extent isn't a whole number of cells — a 3 m wall at 3 cm is, and the
        // whole far wall fell out of the grid.
        let columns = Swift.min(maxDimension, Swift.max(1, Int(extentX / cell) + 1))
        let rows = Swift.min(maxDimension, Swift.max(1, Int(extentZ / cell) + 1))
        // Same trick vertically: cap the slice COUNT and stretch the slice, so a
        // double-height space still maps into the 32-bit mask.
        let sliceCount = Swift.min(maxSlices,
                                   Swift.max(1, Int((extentY / requestedSlice).rounded(.up))))
        let slice = extentY / Float(sliceCount)

        var counts = [Int32](repeating: 0, count: columns * rows)
        var slices = [UInt32](repeating: 0, count: columns * rows)
        let origin = SIMD2<Float>(lo.x, lo.z)
        for p in positions {
            // Clamped, not rejected: the cap above can leave the last cell a
            // sliver short of the extent, and dropping the points that land in
            // it would quietly delete a wall.
            let cx = Swift.min(columns - 1, Swift.max(0, Int((p.x - origin.x) / cell)))
            let cz = Swift.min(rows - 1, Swift.max(0, Int((p.z - origin.y) / cell)))
            let index = cz * columns + cx
            counts[index] &+= 1
            let band = Swift.min(sliceCount - 1, Swift.max(0, Int((p.y - lo.y) / slice)))
            slices[index] |= UInt32(1) << UInt32(band)
        }

        return OccupancyGrid(cellSize: cell, sliceHeight: slice,
                             columns: columns, rows: rows, origin: origin,
                             floorY: lo.y, sliceCount: sliceCount,
                             counts: counts, slices: slices)
    }

    /// Convenience for the app's own cloud type.
    static func build(from cloud: PointCloud,
                      cellSize: Float = defaultCellSize,
                      sliceHeight: Float = defaultSliceHeight) -> OccupancyGrid? {
        build(from: cloud.positions, cellSize: cellSize, sliceHeight: sliceHeight)
    }

    // MARK: - Reading

    @inline(__always)
    func index(x: Int, z: Int) -> Int { z * columns + x }

    func count(x: Int, z: Int) -> Int32 {
        guard x >= 0, x < columns, z >= 0, z < rows else { return 0 }
        return counts[index(x: x, z: z)]
    }

    /// How many height slices this column occupies — the "is it tall" signal.
    func verticalSpan(x: Int, z: Int) -> Int {
        guard x >= 0, x < columns, z >= 0, z < rows else { return 0 }
        return slices[index(x: x, z: z)].nonzeroBitCount
    }

    /// World (x, z) of a column's centre.
    func center(x: Int, z: Int) -> SIMD2<Float> {
        origin + SIMD2<Float>((Float(x) + 0.5) * cellSize, (Float(z) + 0.5) * cellSize)
    }

    /// Columns holding any point at all — the scan's ground footprint.
    var occupiedColumnCount: Int { counts.reduce(0) { $1 > 0 ? $0 + 1 : $0 } }

    // MARK: - Wall extraction

    /// A straight run of wall columns, fitted.
    struct WallRun {
        /// World-space XZ endpoints of the fitted centre line.
        var start: SIMD2<Float>
        var end: SIMD2<Float>
        /// Unit XZ normal (perpendicular to the run).
        var normal: SIMD2<Float>
        var cellCount: Int

        var length: Float { simd_length(end - start) }
        var center: SIMD2<Float> { (start + end) * 0.5 }
    }

    /// Fraction of the scan's height a column must span to read as wall rather
    /// than furniture. Half is deliberate: a wall is usually cut off at the top
    /// by the sweep, and a bookcase should not be allowed to pass.
    static let wallSpanFraction: Float = 0.5
    /// Points a column needs before it counts at all — below this it is stray
    /// depth noise strung down through the slices.
    static let wallMinCount: Int32 = 4
    /// Shortest run that can be a wall (m). Under this it is a furniture edge.
    static let wallMinLength: Float = 0.6
    /// Max secondary/primary variance ratio for a fitted band to be a line. The
    /// gathering band already caps thickness at a few cells, so this is a
    /// backstop against degenerate sets rather than the real filter: a band of
    /// thickness W and length L scores (W/L)², and a corner or blob scores ~1.
    static let wallMaxSpread: Float = 0.25

    /// Angular resolution of the line search: 1° over the half-circle of line
    /// orientations.
    private static let houghAngles = 180
    /// How far off a line a cell may sit and still belong to it, in cells — a
    /// real wall is a band, not a hairline (thickness, LiDAR noise, skirting).
    private static let lineToleranceCells: Float = 2.5
    /// Gap along a line that splits one wall into two runs, in cells. A doorway
    /// is a gap; a missing column behind a chair is not.
    private static let runGapCells = 6

    /// Straight wall runs, longest first.
    ///
    /// A Hough vote rather than connected components: the walls of a closed room
    /// touch at every corner, so flood fill returns the whole room as one blob
    /// that no single line describes. Voting finds each wall independently and
    /// never has to decide where a corner ends. Deterministic — vote, take the
    /// strongest line, refit its cells by PCA, remove them, repeat.
    func wallRuns(maxRuns: Int = 12) -> [WallRun] {
        // A scan under three slices tall has no height signal to threshold on.
        // Grid shape is not a criterion: a sweep of one flat wall is a single
        // row of columns, and it is still a wall.
        guard sliceCount >= 3, maxRuns > 0 else { return [] }
        let minSpan = Swift.max(2, Int((Float(sliceCount) * Self.wallSpanFraction).rounded()))
        let minCells = Swift.max(6, Int(Self.wallMinLength / cellSize) / 2)

        var cells: [SIMD2<Float>] = []
        for z in 0..<rows {
            for x in 0..<columns {
                let i = z * columns + x
                guard counts[i] >= Self.wallMinCount,
                      slices[i].nonzeroBitCount >= minSpan else { continue }
                cells.append(center(x: x, z: z))
            }
        }
        guard cells.count >= minCells else { return [] }

        // Line parameters: θ is the normal's angle over [0, π), ρ = p·n.
        var sinTable = [Float](repeating: 0, count: Self.houghAngles)
        var cosTable = [Float](repeating: 0, count: Self.houghAngles)
        for t in 0..<Self.houghAngles {
            let angle = Float(t) * .pi / Float(Self.houghAngles)
            cosTable[t] = cos(angle)
            sinTable[t] = sin(angle)
        }
        // Vote in coordinates centred on the cells themselves. ARKit's origin is
        // wherever the session started, so world ρ can be tens of metres of empty
        // range — bins the accumulator would carry for nothing.
        var centroid = SIMD2<Float>.zero
        for p in cells { centroid += p }
        centroid /= Float(cells.count)
        for i in 0..<cells.count { cells[i] -= centroid }
        var reach: Float = 0
        for p in cells { reach = Swift.max(reach, simd_length(p)) }
        let rhoMin = -reach, rhoMax = reach
        let rhoStep = cellSize * 1.5
        let rhoBins = Swift.max(1, Int((rhoMax - rhoMin) / rhoStep) + 1)

        @inline(__always)
        func rhoBin(_ p: SIMD2<Float>, _ t: Int) -> Int {
            let rho = p.x * cosTable[t] + p.y * sinTable[t]
            return Swift.min(rhoBins - 1, Swift.max(0, Int((rho - rhoMin) / rhoStep)))
        }

        var votes = [Int32](repeating: 0, count: Self.houghAngles * rhoBins)
        for p in cells {
            for t in 0..<Self.houghAngles {
                votes[t * rhoBins + rhoBin(p, t)] &+= 1
            }
        }

        var alive = [Bool](repeating: true, count: cells.count)
        let tolerance = Self.lineToleranceCells * cellSize
        var runs: [WallRun] = []

        while runs.count < maxRuns {
            var best = 0, bestVotes: Int32 = 0
            for i in 0..<votes.count where votes[i] > bestVotes {
                bestVotes = votes[i]
                best = i
            }
            guard bestVotes >= Int32(minCells) else { break }
            let t = best / rhoBins
            let normal = SIMD2<Float>(cosTable[t], sinTable[t])
            let rho = rhoMin + (Float(best % rhoBins) + 0.5) * rhoStep

            // Everything still unclaimed within the band around that line —
            // gathered by distance, not by bin, so a peak split across two
            // neighbouring bins still collects its whole wall.
            var claimed: [Int] = []
            for i in 0..<cells.count where alive[i] {
                if abs(simd_dot(cells[i], normal) - rho) <= tolerance { claimed.append(i) }
            }
            guard !claimed.isEmpty else { break }
            for i in claimed {
                alive[i] = false
                for angle in 0..<Self.houghAngles {
                    votes[angle * rhoBins + rhoBin(cells[i], angle)] &-= 1
                }
            }
            guard claimed.count >= minCells else { continue }

            let points = claimed.map { cells[$0] }
            guard let fit = fitLine(points) else { continue }
            // Split the band into stretches: one line can carry two walls with a
            // doorway (or a room) between them.
            let sorted = points.map { simd_dot($0 - fit.center, fit.direction) }.sorted()
            let maxGap = Float(Self.runGapCells) * cellSize
            var stretchStart = 0
            for end in 1...sorted.count {
                let broken = end == sorted.count || sorted[end] - sorted[end - 1] > maxGap
                guard broken else { continue }
                defer { stretchStart = end }
                let length = sorted[end - 1] - sorted[stretchStart]
                let count = end - stretchStart
                guard length >= Self.wallMinLength, count >= minCells else { continue }
                runs.append(WallRun(
                    start: centroid + fit.center + fit.direction * sorted[stretchStart],
                    end: centroid + fit.center + fit.direction * sorted[end - 1],
                    normal: SIMD2<Float>(-fit.direction.y, fit.direction.x),
                    cellCount: count))
            }
        }

        return Array(runs.sorted { $0.length > $1.length }.prefix(maxRuns))
    }

    /// Least-squares line through a set of XZ points (PCA), or `nil` when they
    /// are a blob rather than a line. The Hough peak is quantised to a degree
    /// and a bin; this is what makes the emitted geometry exact.
    private func fitLine(_ points: [SIMD2<Float>]) -> (center: SIMD2<Float>,
                                                       direction: SIMD2<Float>)? {
        guard points.count >= 2 else { return nil }
        var mean = SIMD2<Float>.zero
        for p in points { mean += p }
        mean /= Float(points.count)

        var sxx: Float = 0, sxz: Float = 0, szz: Float = 0
        for p in points {
            let d = p - mean
            sxx += d.x * d.x
            sxz += d.x * d.y
            szz += d.y * d.y
        }
        let n = Float(points.count)
        sxx /= n; sxz /= n; szz /= n

        // Analytic 2×2 symmetric eigen-decomposition.
        let trace = sxx + szz
        let diff = sxx - szz
        let root = (diff * diff + 4 * sxz * sxz).squareRoot()
        let primary = (trace + root) * 0.5
        let secondary = (trace - root) * 0.5
        guard primary > 1e-8, secondary / primary <= Self.wallMaxSpread else { return nil }

        let direction: SIMD2<Float>
        if abs(sxz) > 1e-8 {
            direction = simd_normalize(SIMD2<Float>(primary - szz, sxz))
        } else {
            direction = sxx >= szz ? SIMD2<Float>(1, 0) : SIMD2<Float>(0, 1)
        }
        return (mean, direction)
    }

    /// Wall runs as seed planes for the planar regulariser: vertical planes with
    /// a horizontal normal, reaching only as far along the wall as the run
    /// actually ran. Same contract as the ARKit anchors — they SELECT vertices,
    /// the regulariser refits the snap target to the mesh itself.
    func wallSeeds(maxSeeds: Int = 12) -> [SeedPlane] {
        let midHeight = floorY + sliceHeight * Float(sliceCount) * 0.5
        return wallRuns(maxRuns: maxSeeds).map { run in
            let normal = SIMD3<Float>(run.normal.x, 0, run.normal.y)
            let center = SIMD3<Float>(run.center.x, midHeight, run.center.y)
            return SeedPlane(normal: normal,
                             offset: simd_dot(normal, center),
                             center: center,
                             // Half the run, a touch over, exactly like the
                             // anchor path — a seed must not claim the far wall.
                             radius: Swift.max(run.length * 0.55, 0.5))
        }
    }

    // MARK: - Floor plan

    /// A top-down plan straight from the density map, for scans with no
    /// classified mesh. One clean segment per wall run instead of projected
    /// triangle soup; floor area is the scan's ground footprint.
    func floorPlan() -> FloorPlan? {
        let runs = wallRuns(maxRuns: 32)
        guard !runs.isEmpty else { return nil }

        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for z in 0..<rows {
            for x in 0..<columns where counts[z * columns + x] > 0 {
                let c = center(x: x, z: z)
                lo = simd_min(lo, c)
                hi = simd_max(hi, c)
            }
        }
        guard lo.x <= hi.x else { return nil }

        return FloorPlan(wallSegments: runs.map { ($0.start, $0.end) },
                         min: lo, max: hi,
                         floorArea: Float(occupiedColumnCount) * cellSize * cellSize)
    }
}
