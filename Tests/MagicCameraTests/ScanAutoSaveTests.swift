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
}
