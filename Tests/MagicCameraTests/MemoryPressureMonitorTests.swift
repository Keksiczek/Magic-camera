//
//  MemoryPressureMonitorTests.swift
//  MagicCameraTests
//
//  The memory-pressure governor's contract: map the system event to the right
//  severity (critical must win when both bits are set, so we respond to the
//  worse pressure), and broadcast it so the review screen can shed memory / stop
//  the in-flight bake before the system jetsams the app.
//

import XCTest
@testable import MagicCamera

final class MemoryPressureMonitorTests: XCTestCase {

    func testCriticalWinsWhenBothBitsAreSet() {
        XCTAssertEqual(MemoryPressureMonitor.level(for: .warning), .warning)
        XCTAssertEqual(MemoryPressureMonitor.level(for: .critical), .critical)
        // A combined event must resolve to the more severe response, not warning.
        XCTAssertEqual(MemoryPressureMonitor.level(for: [.warning, .critical]), .critical)
    }

    @MainActor
    func testSimulateBroadcastsTheLevel() {
        let received = expectation(forNotification: .memoryPressure, object: nil) { note in
            note.userInfo?[MemoryPressureMonitor.levelKey] as? MemoryPressureLevel == .critical
        }
        MemoryPressureMonitor.shared.simulate(.critical)
        wait(for: [received], timeout: 1)
    }

    /// Responding on an idle scan model must be a safe no-op — no in-flight
    /// operation to cancel, and nothing to shed.
    @MainActor
    func testRespondingWhileIdleIsHarmless() {
        let vm = SpatialScanViewModel()
        vm.respondToMemoryPressure(.warning)
        vm.respondToMemoryPressure(.critical)
        XCTAssertFalse(vm.isBusy)
        XCTAssertFalse(vm.canUndo)
        XCTAssertFalse(vm.canRedo)
    }
}
