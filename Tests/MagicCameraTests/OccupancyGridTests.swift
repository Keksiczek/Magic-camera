//
//  OccupancyGridTests.swift
//  MagicCameraTests
//
//  The bird's-eye density map's contract: a room's four walls come out as four
//  straight runs (the corners must not fuse them into one blob), furniture is
//  not a wall, the seeds it hands the planar regulariser are vertical planes
//  where the walls actually are, and a scan with no walls yields no plan.
//

import XCTest
import simd
@testable import MagicCamera

final class OccupancyGridTests: XCTestCase {

    /// Four walls of a `size`×`size` room, `height` tall, sampled densely enough
    /// to look like a LiDAR sweep of the inside.
    private static func roomWalls(size: Float = 3.0, height: Float = 2.4,
                                  origin: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var along: Float = 0
        while along <= size {
            var y: Float = 0
            while y <= height {
                points.append(origin + SIMD3(along, y, 0))
                points.append(origin + SIMD3(along, y, size))
                points.append(origin + SIMD3(0, y, along))
                points.append(origin + SIMD3(size, y, along))
                y += 0.05
            }
            along += 0.02
        }
        return points
    }

    /// A table: a solid top at 0.75 m and four thin legs down to the floor.
    private static func table(center: SIMD2<Float>, size: Float = 0.8) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var x = -size / 2
        while x <= size / 2 {
            var z = -size / 2
            while z <= size / 2 {
                points.append(SIMD3(center.x + x, 0.75, center.y + z))
                z += 0.02
            }
            x += 0.02
        }
        for leg in [SIMD2<Float>(-1, -1), SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1)] {
            var y: Float = 0
            while y < 0.75 {
                points.append(SIMD3(center.x + leg.x * size / 2, y,
                                    center.y + leg.y * size / 2))
                y += 0.02
            }
        }
        return points
    }

    // MARK: - Build

    func testEmptyCloudHasNoGrid() {
        XCTAssertNil(OccupancyGrid.build(from: []))
    }

    func testGridCoversTheScanAndCountsPoints() throws {
        let walls = Self.roomWalls()
        let grid = try XCTUnwrap(OccupancyGrid.build(from: walls))
        XCTAssertEqual(grid.cellSize, OccupancyGrid.defaultCellSize, accuracy: 1e-6,
                       "a 3 m room fits the grid at the requested resolution")
        XCTAssertEqual(grid.counts.reduce(0) { $0 + Int($1) }, walls.count,
                       "every point lands in a column")
        XCTAssertEqual(grid.sliceCount, 8, "2.4 m of height in 30 cm bands")
    }

    func testAHugeScanGrowsTheCellRatherThanTheGrid() throws {
        // 40 m across — far past 512 cells at 3 cm.
        let grid = try XCTUnwrap(OccupancyGrid.build(from: Self.roomWalls(size: 40)))
        XCTAssertLessThanOrEqual(grid.columns, OccupancyGrid.maxDimension)
        XCTAssertLessThanOrEqual(grid.rows, OccupancyGrid.maxDimension)
        XCTAssertGreaterThan(grid.cellSize, OccupancyGrid.defaultCellSize,
                             "the cell absorbs the extra extent, not the array")
    }

    func testWallColumnsSpanTheHeightAndFurnitureDoesNot() throws {
        let center = SIMD2<Float>(1.5, 1.5)
        let grid = try XCTUnwrap(OccupancyGrid.build(from: Self.roomWalls()
                                                     + Self.table(center: center)))
        // A column on the z = 0 wall, halfway along it.
        let wallX = Int((1.5 - grid.origin.x) / grid.cellSize)
        let wallZ = Int((0 - grid.origin.y) / grid.cellSize)
        XCTAssertEqual(grid.verticalSpan(x: wallX, z: wallZ), grid.sliceCount,
                       "a wall reaches every height band")
        // The middle of the table top.
        let tableX = Int((center.x - grid.origin.x) / grid.cellSize)
        let tableZ = Int((center.y - grid.origin.y) / grid.cellSize)
        XCTAssertGreaterThan(grid.count(x: tableX, z: tableZ), 0, "the table is there")
        XCTAssertLessThan(grid.verticalSpan(x: tableX, z: tableZ), grid.sliceCount / 2,
                          "but it occupies one band, not the room's height")
    }

    // MARK: - Wall runs

    func testFourWallsComeOutAsFourRuns() throws {
        let grid = try XCTUnwrap(OccupancyGrid.build(from: Self.roomWalls()))
        let runs = grid.wallRuns()
        XCTAssertEqual(runs.count, 4, "the corners must not fuse the walls into one blob")
        for run in runs {
            // Not quite the full 3 m: a corner cell belongs to two walls, and
            // whichever line is fitted first claims it, so the later pair comes
            // out a band-width short at each end. Harmless — the seed's reach is
            // deliberately generous — but it is why this isn't 3.0 ± ε.
            XCTAssertGreaterThan(run.length, 2.7, "each run spans its wall")
            XCTAssertLessThanOrEqual(run.length, 3.05, "and no more than its wall")
            XCTAssertEqual(simd_length(run.normal), 1, accuracy: 1e-4)
            // Every wall here is axis-aligned, so each normal is ±X or ±Z.
            let axisAligned = abs(abs(run.normal.x) - 1) < 0.05
                || abs(abs(run.normal.y) - 1) < 0.05
            XCTAssertTrue(axisAligned, "normal is perpendicular to its wall")
        }
    }

    func testFurnitureRaisesNoWall() throws {
        let grid = try XCTUnwrap(OccupancyGrid.build(from: Self.table(center: .zero,
                                                                     size: 2.0)))
        XCTAssertTrue(grid.wallRuns().isEmpty,
                      "a table is wide but short — it is not a wall")
    }

    func testADoorwaySplitsOneWallIntoTwoRuns() throws {
        // A single 4 m wall with a 1 m gap in the middle.
        var points: [SIMD3<Float>] = []
        var x: Float = 0
        while x <= 4 {
            if x < 1.5 || x > 2.5 {
                var y: Float = 0
                while y <= 2.4 {
                    points.append(SIMD3(x, y, 0))
                    y += 0.05
                }
            }
            x += 0.02
        }
        let grid = try XCTUnwrap(OccupancyGrid.build(from: points))
        let runs = grid.wallRuns()
        XCTAssertEqual(runs.count, 2, "the gap breaks the run, it does not bridge it")
        for run in runs {
            XCTAssertEqual(run.length, 1.5, accuracy: 0.2)
        }
    }

    func testRunsSurviveAScanFarFromTheWorldOrigin() throws {
        // ARKit's origin is wherever the session started.
        let grid = try XCTUnwrap(OccupancyGrid.build(
            from: Self.roomWalls(origin: SIMD3(120, 0, -85))))
        let runs = grid.wallRuns()
        XCTAssertEqual(runs.count, 4)
        for run in runs {
            XCTAssertEqual(run.center.x, 121.5, accuracy: 1.6, "runs stay where the room is")
            XCTAssertEqual(run.center.y, -83.5, accuracy: 1.6)
        }
    }

    // MARK: - Seeds

    func testSeedsAreVerticalPlanesOnTheWalls() throws {
        let grid = try XCTUnwrap(OccupancyGrid.build(from: Self.roomWalls()))
        let seeds = grid.wallSeeds()
        XCTAssertEqual(seeds.count, 4)
        for seed in seeds {
            XCTAssertEqual(seed.normal.y, 0, accuracy: 1e-5, "a wall seed is vertical")
            XCTAssertEqual(simd_length(seed.normal), 1, accuracy: 1e-4)
            // The plane passes through its own centre, by construction.
            XCTAssertEqual(simd_dot(seed.normal, seed.center), seed.offset, accuracy: 1e-3)
            XCTAssertGreaterThan(seed.radius, 1.0, "reaches along its wall")
            XCTAssertLessThan(seed.radius, 3.0, "but cannot claim the far wall")
        }
        // Two opposite pairs: the z = 0 / z = 3 walls, and x = 0 / x = 3.
        let offsets = seeds.map { abs($0.offset) }.sorted()
        XCTAssertEqual(offsets[0], 0, accuracy: 0.1)
        XCTAssertEqual(offsets[1], 0, accuracy: 0.1)
        XCTAssertEqual(offsets[2], 3, accuracy: 0.1)
        XCTAssertEqual(offsets[3], 3, accuracy: 0.1)
    }

    // MARK: - Floor plan

    func testFloorPlanFromACloudWithNoClassification() throws {
        let cloud = PointCloud.from(positions: Self.roomWalls())
        let plan = try XCTUnwrap(FloorPlanBuilder.build(from: cloud),
                                 "an unclassified point scan still gets a plan")
        XCTAssertEqual(plan.wallSegments.count, 4)
        XCTAssertEqual(plan.size.x, 3.0, accuracy: 0.1)
        XCTAssertEqual(plan.size.y, 3.0, accuracy: 0.1)
        // Only the walls were scanned, so the footprint is their ring, not 9 m².
        XCTAssertGreaterThan(plan.floorArea, 0)
        XCTAssertLessThan(plan.floorArea, 9)
    }

    func testNoWallsMeansNoPlan() throws {
        let cloud = PointCloud.from(positions: Self.table(center: .zero, size: 2.0))
        XCTAssertNil(FloorPlanBuilder.build(from: cloud))
    }
}

private extension PointCloud {
    static func from(positions: [SIMD3<Float>]) -> PointCloud {
        var cloud = PointCloud()
        cloud.reserveCapacity(positions.count)
        for p in positions {
            cloud.append(position: p, color: SIMD3(repeating: 0.5), confidence: 1)
        }
        return cloud
    }
}
