//
//  ScanAutoSaveTests.swift
//  MagicCameraTests
//
//  The crash-recovery autosave cadence scales with cloud size so a big scan
//  doesn't churn gigabytes of disk writes over a session (the r27 diskWrites
//  watchdog) while a small scan still checkpoints promptly.
//

import XCTest
@testable import MagicCamera

final class ScanAutoSaveTests: XCTestCase {

    private func seconds(_ count: Int) -> Double {
        let d = SpatialScanViewModel.autosaveInterval(forCount: count)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    func testSmallScanKeepsBaseInterval() {
        XCTAssertEqual(seconds(0), 12, accuracy: 1e-6)
        XCTAssertEqual(seconds(100_000), 12 + 18 * 0.1, accuracy: 1e-6)   // 10 % of the ramp
    }

    func testBigScanStretchesToCeiling() {
        XCTAssertEqual(seconds(1_000_000), 30, accuracy: 1e-6)
        XCTAssertEqual(seconds(5_000_000), 30, accuracy: 1e-6)   // clamped, not runaway
    }

    func testIntervalIsMonotonic() {
        var previous = seconds(0)
        for count in stride(from: 0, through: 1_200_000, by: 100_000) {
            let current = seconds(count)
            XCTAssertGreaterThanOrEqual(current, previous)
            XCTAssertLessThanOrEqual(current, 30)
            previous = current
        }
    }

    /// Autosave rewrites the WHOLE cloud, so what it costs is the sum of every
    /// snapshot. The threshold is what bounds that sum to a small multiple of
    /// the final size — the property, not the constant, is what is asserted.
    func testTotalWritesAreBoundedByASmallMultipleOfTheFinalCloud() {
        func totalWritten(overBudget: Bool) -> Double {
            var saved = 0
            var bytes = 0.0
            let final = 1_400_000
            for live in stride(from: 0, through: final, by: 1_000) {
                let need = SpatialScanViewModel.autosaveGrowthThreshold(
                    saved: saved, overBudget: overBudget)
                if live - saved >= need {
                    saved = live
                    bytes += Double(saved)   // every rewrite costs the whole cloud
                }
            }
            return bytes / Double(final)
        }
        // The old rule (a sixth) came to ~7x the final cloud; a device session
        // billed 639 MB for ~32 MB of clouds and tripped a MetricKit exception.
        XCTAssertLessThan(totalWritten(overBudget: false), 5.0,
                          "a scan must not write many times its own size")
        XCTAssertLessThan(totalWritten(overBudget: true),
                          totalWritten(overBudget: false),
                          "past the budget it must back off further")
    }

    func testSmallScansStillCheckpointOften() {
        // Early growth is cheap, so the floor keeps it frequent.
        XCTAssertEqual(SpatialScanViewModel.autosaveGrowthThreshold(saved: 0, overBudget: false),
                       25_000)
        XCTAssertEqual(SpatialScanViewModel.autosaveGrowthThreshold(saved: 30_000, overBudget: false),
                       25_000)
    }
}
