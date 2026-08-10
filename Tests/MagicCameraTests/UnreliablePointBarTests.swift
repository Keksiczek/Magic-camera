//
//  UnreliablePointBarTests.swift
//  MagicCameraTests
//
//  The "Filtering reflections" step is meant to take a tail — glossy multipath,
//  which grades badly — off a scan. It is the first step of the standard Surface
//  recipe, so it runs unattended on every room. These pin what it may remove.
//

import XCTest
@testable import MagicCamera

final class UnreliablePointBarTests: XCTestCase {

    /// Confidences spread evenly over `low...high`.
    private func spread(_ low: Float, _ high: Float, count: Int = 10_000) -> [Float] {
        (0..<count).map { low + (high - low) * Float($0) / Float(count - 1) }
    }

    private func dropped(_ confidences: [Float]) -> Int {
        let bar = SpatialScanViewModel.unreliableBar(for: confidences)
        return confidences.filter { $0 < bar }.count
    }

    func testAHealthyScanLosesOnlyItsDoubtfulTail() {
        // A well-graded object sweep: mean ~0.8, a thin bad tail.
        let confidences = spread(0.6, 1.0) + spread(0.0, 0.25, count: 300)
        XCTAssertEqual(SpatialScanViewModel.unreliableBar(for: confidences),
                       DepthSampleConfidence.lowConfidenceMark)
        XCTAssertLessThan(Float(dropped(confidences)) / Float(confidences.count), 0.05)
    }

    func testTheBarIsTheGradingsOwnDoubtfulMarkNotAHigherOne() {
        // The device room: `mean 0.62`, and the old hardcoded 0.65 sat above it,
        // so the step deleted half the scan — and not evenly. A table in the
        // middle of a room grades lower than the walls around it, so the table is
        // what went.
        let room = spread(0.05, 1.0)
        let bar = SpatialScanViewModel.unreliableBar(for: room)
        XCTAssertLessThan(bar, 0.65, "0.65 is above what a whole room averages")
        XCTAssertLessThan(Float(dropped(room)) / Float(room.count), 0.25)
    }

    func testAScanThatGradedBadlyIsThinnedNotGutted() {
        // Everything doubtful. The mark alone would take the lot; the cap holds
        // it to a third, because a badly graded scan is still the user's scan.
        let poor = spread(0.02, 0.24)
        let removed = Float(dropped(poor)) / Float(poor.count)
        XCTAssertLessThanOrEqual(removed, 1.0 / 3 + 0.001)
        XCTAssertGreaterThan(removed, 0.3, "it still takes the worst of it")
    }

    func testAnAllGoodScanLosesNothing() {
        let clean = spread(0.7, 1.0)
        XCTAssertEqual(dropped(clean), 0)
    }

    func testEmptyInputIsHarmless() {
        XCTAssertEqual(SpatialScanViewModel.unreliableBar(for: []),
                       DepthSampleConfidence.lowConfidenceMark)
    }
}
