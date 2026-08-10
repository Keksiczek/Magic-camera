//
//  ScanMetrics.swift
//  Magic Camera
//
//  What a scan is, measured from the scan itself.
//
//  Everything the app said about a capture came from its bounding box: the name
//  ("Room 4.2×6.3 m"), the gallery subtitle, the share text. A bounding box is a
//  poor witness. It calls an L-shaped flat a rectangle, it counts the metre of
//  empty air above a table as part of the table, and it cannot tell a room the
//  user walked through from a wall they pointed at for ten seconds.
//
//  This measures the occupied space instead, reusing the bird's-eye occupancy
//  grid the wall finder already builds: the footprint is the columns that
//  actually hold points, the height is the gap between the floor and ceiling
//  bands rather than the extent of the noise, and the kind is decided by whether
//  the capture has a floor AND a ceiling with room between them.
//
//  Pure value math, ARKit-free, off-main — and no `Measurement`/`Formatter`
//  work happens in here, so it is cheap enough to run on every save.
//

import simd

struct ScanMetrics: Equatable, Sendable {

    /// What the capture turned out to be — decided by the geometry, not by the
    /// mode the user picked, so a "Room" sweep of a single cupboard still reads
    /// as an object and gets named like one.
    enum Kind: String, Sendable {
        case object       // hand-sized to furniture-sized, no room around it
        case surface      // a wall, a floor, a table top: broad but flat
        case room         // a floor and a ceiling with standing height between
        case area         // bigger than one room — a flat, a hall, outdoors

        var label: String {
            switch self {
            case .object:  return "Object"
            case .surface: return "Surface"
            case .room:    return "Room"
            case .area:    return "Area"
            }
        }
    }

    var kind: Kind
    /// Bounding dimensions, largest first (m).
    var dimensions: SIMD3<Float>
    /// Ground area the capture actually occupies (m²) — occupied columns of the
    /// bird's-eye grid, NOT the bounding rectangle. An L-shaped flat measures L.
    var footprintArea: Float
    /// Floor-to-ceiling height (m), or nil when the capture has no ceiling.
    var roomHeight: Float?
    /// Rough enclosed volume (m³): footprint × height for a space, the occupied
    /// voxel volume for an object.
    var volume: Float
    /// Points per m² of footprint — how densely the thing was actually swept.
    var pointDensity: Float
    var pointCount: Int

    /// Longest dimension (m) — the number people reach for first.
    var largestDimension: Float { dimensions.x }

    // MARK: - Thresholds
    //
    // Named, because every one of them is a judgement call and the next person
    // to disagree should be able to find it.

    /// Above this the capture is a space you stand in rather than a thing you
    /// hold. Deliberately below a real room: a 1.2 m sweep of a desk is already
    /// past "object".
    static let objectCeiling: Float = 1.2
    /// Standing height. Below it, a "room" is really a shelf or a stairwell.
    static let minimumRoomHeight: Float = 1.6
    /// Past this footprint one room is no longer the honest description.
    static let roomFootprintCeiling: Float = 45
    /// A capture flatter than this (thinnest ÷ longest) is a surface, whatever
    /// its area — the wall, the floor, the table top.
    static let surfaceFlatness: Float = 0.08

    // MARK: - Measuring

    /// Measures a captured cloud. Returns nil for a cloud too small to say
    /// anything honest about.
    static func measure(_ cloud: PointCloud) -> ScanMetrics? {
        measure(positions: cloud.positions)
    }

    static func measure(positions: [SIMD3<Float>]) -> ScanMetrics? {
        guard positions.count >= 100 else { return nil }

        var lo = positions[0], hi = positions[0]
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let extent = hi - lo
        let sorted = [extent.x, extent.y, extent.z].sorted(by: >)
        let dimensions = SIMD3<Float>(sorted[0], sorted[1], sorted[2])

        // The grid gives the footprint and the height bands in one pass. Without
        // it (a degenerate cloud) fall back to the bounding box, which is what
        // the app used to do for everything.
        guard let grid = OccupancyGrid.build(from: positions) else {
            return ScanMetrics(kind: kind(dimensions: dimensions,
                                          footprintArea: extent.x * extent.z,
                                          roomHeight: nil),
                               dimensions: dimensions,
                               footprintArea: extent.x * extent.z,
                               roomHeight: nil,
                               volume: extent.x * extent.y * extent.z,
                               pointDensity: Float(positions.count)
                                   / Swift.max(extent.x * extent.z, 0.0001),
                               pointCount: positions.count)
        }

        let cellArea = grid.cellSize * grid.cellSize
        let footprintArea = Float(occupiedColumns(grid)) * cellArea

        let height = ceilingHeight(positions: positions, extent: extent)
        let resolvedKind = kind(dimensions: dimensions,
                                footprintArea: footprintArea,
                                roomHeight: height)
        // A space is hollow, so its volume is the footprint swept up to the
        // ceiling. An object is not, so charging it the full bounding prism
        // would triple a bowl — use the occupied columns times its own height.
        let volume: Float
        switch resolvedKind {
        case .room, .area:
            volume = footprintArea * (height ?? dimensions[1])
        case .object, .surface:
            volume = footprintArea * extent.y
        }

        return ScanMetrics(kind: resolvedKind,
                           dimensions: dimensions,
                           footprintArea: footprintArea,
                           roomHeight: height,
                           volume: volume,
                           pointDensity: Float(positions.count)
                               / Swift.max(footprintArea, 0.0001),
                           pointCount: positions.count)
    }

    /// Columns of the grid that count as floor, after closing the gaps a sparse
    /// sweep leaves between its samples.
    ///
    /// Counting occupied cells directly measures the SAMPLING, not the room: the
    /// grid's cell is 3 cm, so a floor swept at 5 cm spacing lights up about a
    /// third of its own cells and a 27 m² flat reports 10. One dilate-then-erode
    /// pass fills a one-cell gap without growing the outline — a floor with gaps
    /// between its samples is still a floor, and the boundary stays where the
    /// data ends, which is what makes the number an area rather than a guess.
    private static func occupiedColumns(_ grid: OccupancyGrid) -> Int {
        let columns = grid.columns, rows = grid.rows
        var mask = [Bool](repeating: false, count: columns * rows)
        for i in 0..<mask.count where grid.counts[i] > 0 { mask[i] = true }

        @inline(__always)
        func neighbourhood(_ source: [Bool], wantsAll: Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: source.count)
            for z in 0..<rows {
                for x in 0..<columns {
                    var any = false, all = true
                    for dz in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, nz = z + dz
                            let inside = nx >= 0 && nx < columns && nz >= 0 && nz < rows
                            let set = inside && source[nz * columns + nx]
                            any = any || set
                            all = all && set
                        }
                    }
                    out[z * columns + x] = wantsAll ? all : any
                }
            }
            return out
        }
        let closed = neighbourhood(neighbourhood(mask, wantsAll: false), wantsAll: true)
        // Erosion cannot resurrect a cell the original never had a claim on, but
        // it can shave a legitimately thin one — so keep the union.
        var count = 0
        for i in 0..<mask.count where mask[i] || closed[i] { count += 1 }
        return count
    }

    /// Floor-to-ceiling height, or nil when there is no ceiling to speak of.
    ///
    /// Both surfaces are the densest horizontal bands in their half of the
    /// capture — a real ceiling is swept as one broad slab, and nothing else in
    /// a room competes with it for that. Nil rather than a guess when the two
    /// bands are too close to be a storey: an unroofed sweep should say so.
    private static func ceilingHeight(positions: [SIMD3<Float>],
                                      extent: SIMD3<Float>) -> Float? {
        guard extent.y >= minimumRoomHeight else { return nil }
        let bin: Float = 0.05
        var lo = positions[0].y, hi = positions[0].y
        for p in positions {
            lo = Swift.min(lo, p.y)
            hi = Swift.max(hi, p.y)
        }
        let bins = Swift.max(2, Int((hi - lo) / bin) + 1)
        var histogram = [Int](repeating: 0, count: bins)
        for p in positions {
            histogram[Swift.min(bins - 1, Swift.max(0, Int((p.y - lo) / bin)))] += 1
        }
        let mid = bins / 2
        var floorBin = 0, ceilingBin = mid
        for i in 0..<mid where histogram[i] > histogram[floorBin] { floorBin = i }
        for i in mid..<bins where histogram[i] > histogram[ceilingBin] { ceilingBin = i }
        // Both bands have to be real: a sweep with no ceiling still has a
        // densest upper bin, it is just nothing in particular.
        let floorWeight = histogram[floorBin], ceilingWeight = histogram[ceilingBin]
        let mean = Float(positions.count) / Float(bins)
        guard Float(floorWeight) > mean * 2, Float(ceilingWeight) > mean * 2 else {
            return nil
        }
        let height = Float(ceilingBin - floorBin) * bin
        return height >= minimumRoomHeight ? height : nil
    }

    private static func kind(dimensions: SIMD3<Float>,
                             footprintArea: Float,
                             roomHeight: Float?) -> Kind {
        // Flatness first: a 4 m wall is not a room, however wide it is, and
        // calling it one produces the "Room 0.1 m tall" names the box gave.
        let flatness = dimensions[2] / Swift.max(dimensions[0], 0.0001)
        if dimensions[0] >= objectCeiling, flatness < surfaceFlatness { return .surface }
        guard dimensions[0] >= objectCeiling else { return .object }
        guard roomHeight != nil else { return .surface }
        return footprintArea > roomFootprintCeiling ? .area : .room
    }
}
