//
//  ScanMetricsTests.swift
//  MagicCameraTests
//
//  Everything the app said about a capture came from its bounding box. These
//  pin what the measured version says instead — especially the cases the box
//  got wrong: the L-shaped room, the table with air above it, the wall that is
//  not a room.
//

import XCTest
import simd
@testable import MagicCamera

final class ScanMetricsTests: XCTestCase {

    // MARK: - Builders

    /// A box-shaped room: floor, ceiling and four walls, sampled at `step`.
    private func room(width: Float, depth: Float, height: Float,
                      step: Float = 0.04) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var x: Float = 0
        while x <= width {
            var z: Float = 0
            while z <= depth {
                points.append(SIMD3(x, 0, z))          // floor
                points.append(SIMD3(x, height, z))     // ceiling
                z += step
            }
            var y: Float = 0
            while y <= height {
                points.append(SIMD3(x, y, 0))
                points.append(SIMD3(x, y, depth))
                y += step
            }
            x += step
        }
        var z: Float = 0
        while z <= depth {
            var y: Float = 0
            while y <= height {
                points.append(SIMD3(0, y, z))
                points.append(SIMD3(width, y, z))
                y += step
            }
            z += step
        }
        return points
    }

    /// A solid box of surface points — a crate, a bowl, anything hand-sized.
    private func object(size: SIMD3<Float>, step: Float = 0.004) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var x: Float = 0
        while x <= size.x {
            var y: Float = 0
            while y <= size.y {
                points.append(SIMD3(x, y, 0))
                points.append(SIMD3(x, y, size.z))
                y += step
            }
            var z: Float = 0
            while z <= size.z {
                points.append(SIMD3(x, 0, z))
                points.append(SIMD3(x, size.y, z))
                z += step
            }
            x += step
        }
        return points
    }

    // MARK: - Kind

    func testARoomIsRecognisedByHavingAFloorAndACeiling() throws {
        let metrics = try XCTUnwrap(ScanMetrics.measure(positions: room(width: 4, depth: 6, height: 2.5)))
        XCTAssertEqual(metrics.kind, .room)
        XCTAssertEqual(try XCTUnwrap(metrics.roomHeight), 2.5, accuracy: 0.1)
    }

    func testAWallIsASurfaceNotARoom() throws {
        // 4 × 2.5 m of wall and nothing else. The bounding box calls this a room
        // 4 m across; it has no floor to stand on.
        var points: [SIMD3<Float>] = []
        var x: Float = 0
        while x <= 4 {
            var y: Float = 0
            while y <= 2.5 { points.append(SIMD3(x, y, 0)); y += 0.02 }
            x += 0.02
        }
        let metrics = try XCTUnwrap(ScanMetrics.measure(positions: points))
        XCTAssertEqual(metrics.kind, .surface)
        XCTAssertNil(metrics.roomHeight)
    }

    func testAHandSizedCaptureIsAnObject() throws {
        let metrics = try XCTUnwrap(ScanMetrics.measure(
            positions: object(size: SIMD3(0.18, 0.12, 0.09))))
        XCTAssertEqual(metrics.kind, .object)
        XCTAssertEqual(metrics.largestDimension, 0.18, accuracy: 0.01)
    }

    func testAFlatBiggerThanOneRoomReadsAsAnArea() throws {
        let metrics = try XCTUnwrap(ScanMetrics.measure(
            positions: room(width: 9, depth: 8, height: 2.5, step: 0.06)))
        XCTAssertEqual(metrics.kind, .area, "72 m² is past one room")
    }

    // MARK: - Footprint

    func testAnLShapedRoomMeasuresTheLNotItsBoundingRectangle() throws {
        // Two 3×3 m wings sharing a corner: 27 m² of floor inside a 6×6 = 36 m²
        // box. The box name was wrong by a third of the flat.
        var points = room(width: 6, depth: 3, height: 2.5, step: 0.05)
        points += room(width: 3, depth: 6, height: 2.5, step: 0.05)
        let metrics = try XCTUnwrap(ScanMetrics.measure(positions: points))
        XCTAssertLessThan(metrics.footprintArea, 34, "the missing wing is not floor")
        XCTAssertGreaterThan(metrics.footprintArea, 20,
                             "and the swept wings are, gaps between samples included")
        // The bounding box, for contrast, is the full 6 × 6.
        XCTAssertEqual(metrics.dimensions[0], 6, accuracy: 0.1)
    }

    func testFootprintIgnoresTheAirAboveATable() throws {
        // A 1.2 × 0.8 m table top at 0.75 m. Its footprint is the top, not the
        // volume of the room-shaped box the extent describes.
        var points: [SIMD3<Float>] = []
        var x: Float = 0
        while x <= 1.2 {
            var z: Float = 0
            while z <= 0.8 { points.append(SIMD3(x, 0.75, z)); z += 0.01 }
            x += 0.01
        }
        let metrics = try XCTUnwrap(ScanMetrics.measure(positions: points))
        XCTAssertEqual(metrics.footprintArea, 0.96, accuracy: 0.15)
    }

    // MARK: - Robustness

    func testTooFewPointsMeasureToNothingRatherThanToAGuess() {
        XCTAssertNil(ScanMetrics.measure(positions: []))
        XCTAssertNil(ScanMetrics.measure(positions: (0..<50).map {
            SIMD3(Float($0) * 0.01, 0, 0)
        }))
    }

    func testDensityIsPerSquareMetreOfWhatWasActuallySwept() throws {
        let metrics = try XCTUnwrap(ScanMetrics.measure(positions: room(width: 4, depth: 4, height: 2.5)))
        XCTAssertGreaterThan(metrics.pointDensity, 0)
        XCTAssertEqual(metrics.pointDensity,
                       Float(metrics.pointCount) / metrics.footprintArea, accuracy: 1)
    }

    // MARK: - Text

    func testNamesSayWhatTheThingIs() throws {
        let roomMetrics = try XCTUnwrap(ScanMetrics.measure(positions: room(width: 4, depth: 6, height: 2.5)))
        XCTAssertTrue(roomMetrics.name().hasPrefix("Room "), roomMetrics.name())
        XCTAssertTrue(roomMetrics.name().contains("m²"), roomMetrics.name())

        let objectMetrics = try XCTUnwrap(ScanMetrics.measure(
            positions: object(size: SIMD3(0.18, 0.12, 0.09))))
        XCTAssertTrue(objectMetrics.name().hasPrefix("Object "), objectMetrics.name())
        XCTAssertTrue(objectMetrics.name().contains("cm"), objectMetrics.name())
    }

    func testANameIsSafeToUseAsAFileName() throws {
        let metrics = try XCTUnwrap(ScanMetrics.measure(positions: room(width: 4, depth: 6, height: 2.5)))
        let name = metrics.name()
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"), "a colon from the clock would break the path")
    }

    func testTheSummaryCarriesEveryRow() throws {
        let metrics = try XCTUnwrap(ScanMetrics.measure(positions: room(width: 4, depth: 6, height: 2.5)))
        let lines = metrics.summaryText.split(separator: "\n")
        XCTAssertEqual(lines.count, metrics.rows.count)
        XCTAssertTrue(metrics.summaryText.contains("Floor area"))
        XCTAssertTrue(metrics.summaryText.contains("Ceiling height"))
    }

    func testUnitsSwitchAtTheRightScale() {
        XCTAssertTrue(ScanMetrics.length(0.42).hasSuffix("cm"))
        XCTAssertTrue(ScanMetrics.length(2.5).hasSuffix("m"))
        XCTAssertTrue(ScanMetrics.area(0.3).hasSuffix("cm²"))
        XCTAssertTrue(ScanMetrics.area(23.4).hasSuffix("m²"))
        XCTAssertTrue(ScanMetrics.volume(0.02).hasSuffix("cm³"))
        XCTAssertTrue(ScanMetrics.volume(31.0).hasSuffix("m³"))
    }
}
