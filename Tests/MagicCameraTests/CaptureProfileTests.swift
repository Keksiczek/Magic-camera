//
//  CaptureProfileTests.swift
//  Magic Camera
//
//  The split of `CaptureQuality` into subject × detail makes one claim that has
//  to be checkable rather than believed: **the five combinations that existed
//  before behave identically**. A capture preset is a dozen coupled numbers that
//  took device rounds each to settle — range, voxel, coarsening band, carve
//  strength, edge threshold — and a refactor that quietly moved one of them would
//  surface as "scans got worse" weeks later, with the refactor long forgotten.
//
//  So every field of every legacy pair is compared against the old enum here.
//

import XCTest
@testable import MagicCamera

final class CaptureProfileTests: XCTestCase {

    /// Every field that decides what a capture does, EXCEPT `maxPoints`.
    ///
    /// The point budget deliberately no longer comes from the profile. It moved
    /// with the detail tier until it was the thing deciding how much of a room a
    /// scan could cover — a long sweep saturated the cap partway and stopped
    /// growing, so the far half never made it in. It is now one device-capability
    /// setting (`CaptureBudget`), asserted separately below, because a ceiling
    /// that protects the phone and a dial that sets detail are different things.
    ///
    /// Everything else is compared wholesale, so a new `ScanConfig` field cannot
    /// slip past by not being listed.
    private func assertSameConfig(_ a: ScanConfig, _ b: ScanConfig,
                                  _ label: String, file: StaticString = #filePath,
                                  line: UInt = #line) {
        XCTAssertEqual(a.frameStride, b.frameStride, "\(label) frameStride", file: file, line: line)
        XCTAssertEqual(a.pixelStride, b.pixelStride, "\(label) pixelStride", file: file, line: line)
        XCTAssertEqual(a.minConfidence, b.minConfidence, "\(label) minConfidence", file: file, line: line)
        XCTAssertEqual(a.voxelSize, b.voxelSize, accuracy: 1e-6, "\(label) voxelSize", file: file, line: line)
        XCTAssertEqual(a.maxDepth, b.maxDepth, accuracy: 1e-6, "\(label) maxDepth", file: file, line: line)
        XCTAssertEqual(a.edgeThreshold, b.edgeThreshold, accuracy: 1e-6, "\(label) edgeThreshold", file: file, line: line)
        XCTAssertEqual(a.adaptiveVoxelEnabled, b.adaptiveVoxelEnabled, "\(label) adaptiveVoxel", file: file, line: line)
        XCTAssertEqual(a.adaptiveVoxelNearDistance, b.adaptiveVoxelNearDistance, accuracy: 1e-6,
                       "\(label) adaptiveVoxelNearDistance", file: file, line: line)
        XCTAssertEqual(a.carveEnabled, b.carveEnabled, "\(label) carveEnabled", file: file, line: line)
        XCTAssertEqual(a.carveStrength, b.carveStrength, accuracy: 1e-6, "\(label) carveStrength", file: file, line: line)
        XCTAssertEqual(a.wantsPlanes, b.wantsPlanes, "\(label) wantsPlanes", file: file, line: line)
        XCTAssertEqual(a.wantsSceneMesh, b.wantsSceneMesh, "\(label) wantsSceneMesh", file: file, line: line)
        XCTAssertEqual(a.steadyMaxAngularSpeed, b.steadyMaxAngularSpeed, accuracy: 1e-6,
                       "\(label) steadyMaxAngularSpeed", file: file, line: line)
        XCTAssertEqual(a.steadyMaxLinearSpeed, b.steadyMaxLinearSpeed, accuracy: 1e-6,
                       "\(label) steadyMaxLinearSpeed", file: file, line: line)
        XCTAssertEqual(a.contentAdaptiveEnabled, b.contentAdaptiveEnabled,
                       "\(label) contentAdaptive", file: file, line: line)
    }

    // MARK: - The five old combinations are unchanged

    func testLegacyCombinationsProduceTheSameCapture() {
        for legacy in CaptureQuality.allCases {
            let profile = CaptureProfile(legacy: legacy)
            XCTAssertTrue(profile.isLegacyCombination, "\(legacy.rawValue) should map to a shipped pair")
            let expected = legacy == .object
                ? CaptureQuality.objectConfig(fine: false, rangeMeters: 1.5)
                : legacy.scanConfig
            assertSameConfig(profile.scanConfig(), expected, legacy.rawValue)
            XCTAssertEqual(profile.scanConfig().maxPoints, CaptureBudget.selected.maxPoints,
                           "\(legacy.rawValue) must take its budget from the device setting")
        }
    }

    func testLegacyCombinationsProduceTheSameReconstruction() {
        for legacy in CaptureQuality.allCases {
            let profile = CaptureProfile(legacy: legacy)
            XCTAssertEqual(profile.reconstructDetail, legacy.reconstructDetail,
                           "\(legacy.rawValue) detail")
            XCTAssertEqual(profile.reconstructMethod, legacy.reconstructMethod,
                           "\(legacy.rawValue) method")
            XCTAssertEqual(profile.scanQuality, legacy.scanQuality, "\(legacy.rawValue) preset")
        }
    }

    /// Object's own extras must still reach the config unchanged.
    func testObjectExtrasStillApply() {
        let profile = CaptureProfile(subject: .object, detail: .max)
        let fine = profile.scanConfig(fine: true, rangeMeters: 2.2)
        assertSameConfig(fine, CaptureQuality.objectConfig(fine: true, rangeMeters: 2.2), "Object+")
        XCTAssertEqual(fine.maxPoints, CaptureBudget.selected.maxPoints)
        XCTAssertEqual(fine.voxelSize, 0.002, accuracy: 1e-6)
        XCTAssertEqual(fine.maxDepth, 2.2, accuracy: 1e-6)
    }

    // MARK: - The four new combinations

    /// The whole point of the split: a room can now be scanned quickly and an
    /// object thoroughly-but-not-maximally, and each moves ONLY the density.
    func testNewCombinationsMoveDensityAndNothingElse() {
        let cases: [(CaptureSubject, CaptureDetail)] = [
            (.object, .quick), (.object, .balanced), (.room, .quick), (.room, .max),
        ]
        for (subject, detail) in cases {
            let native = CaptureProfile(subject: subject, detail: subject.nativeDetail).scanConfig()
            let moved = CaptureProfile(subject: subject, detail: detail).scanConfig()
            let label = "\(subject.rawValue) × \(detail.rawValue)"

            // Everything that describes the SUBJECT is untouched.
            XCTAssertEqual(moved.maxDepth, native.maxDepth, accuracy: 1e-6, "\(label) range moved")
            XCTAssertEqual(moved.edgeThreshold, native.edgeThreshold, accuracy: 1e-6, "\(label) edge moved")
            XCTAssertEqual(moved.carveStrength, native.carveStrength, accuracy: 1e-6, "\(label) carve moved")
            XCTAssertEqual(moved.adaptiveVoxelEnabled, native.adaptiveVoxelEnabled, "\(label) coarsening moved")
            XCTAssertEqual(moved.wantsSceneMesh, native.wantsSceneMesh, "\(label) scene mesh moved")
            XCTAssertEqual(moved.wantsPlanes, native.wantsPlanes, "\(label) planes moved")

            // …and the DENSITY moved in the direction asked for.
            if detail.rank < subject.nativeDetail.rank {
                XCTAssertGreaterThan(moved.voxelSize, native.voxelSize, "\(label) should be coarser")
            } else {
                XCTAssertLessThan(moved.voxelSize, native.voxelSize, "\(label) should be finer")
            }
            // The budget is NOT a detail dial. A coarser tier must buy a larger
            // area at the same ceiling, not a smaller scan — that coupling is what
            // truncated long room sweeps.
            XCTAssertEqual(moved.maxPoints, native.maxPoints,
                           "\(label) must not move the point budget")
            XCTAssertFalse(CaptureProfile(subject: subject, detail: detail).isLegacyCombination,
                           "\(label) is new and should say so")
        }
    }

    /// No combination may ask for a point budget the device cannot hold.
    func testEveryCombinationStaysWithinItsCeiling() {
        for subject in CaptureSubject.allCases {
            for detail in CaptureDetail.allCases {
                let config = CaptureProfile(subject: subject, detail: detail).scanConfig()
                let label = "\(subject.rawValue) × \(detail.rawValue)"
                XCTAssertGreaterThan(config.voxelSize, 0, "\(label) voxel")
                XCTAssertLessThanOrEqual(config.maxPoints, 4_000_000, "\(label) point budget")
                XCTAssertGreaterThan(config.maxPoints, 0, "\(label) point budget")
                XCTAssertGreaterThan(config.maxDepth, 0, "\(label) range")
            }
        }
    }

    /// Detail must be monotonic within a subject — a higher tier can never cost
    /// less, or the picker is lying about what it does.
    func testDetailIsMonotonicWithinASubject() {
        for subject in CaptureSubject.allCases {
            let quick = CaptureProfile(subject: subject, detail: .quick).scanConfig()
            let balanced = CaptureProfile(subject: subject, detail: .balanced).scanConfig()
            let best = CaptureProfile(subject: subject, detail: .max).scanConfig()
            XCTAssertGreaterThanOrEqual(quick.voxelSize, balanced.voxelSize, "\(subject.rawValue) quick/balanced")
            XCTAssertGreaterThanOrEqual(balanced.voxelSize, best.voxelSize, "\(subject.rawValue) balanced/max")
            XCTAssertLessThanOrEqual(quick.maxPoints, balanced.maxPoints, "\(subject.rawValue) quick/balanced points")
            XCTAssertLessThanOrEqual(balanced.maxPoints, best.maxPoints, "\(subject.rawValue) balanced/max points")
        }
    }

    func testDefaultProfileIsARoomAtItsNativeDetail() {
        let profile = CaptureProfile()
        XCTAssertEqual(profile.subject, .room)
        XCTAssertEqual(profile.detail, .balanced)
        XCTAssertEqual(profile.detailOffset, 0)
        XCTAssertTrue(profile.isLegacyCombination)
    }
}

/// The point budget as a device-capability ceiling rather than a detail dial.
final class CaptureBudgetTests: XCTestCase {

    private let key = "settings.pointBudget"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultsToWhatRoomScansAlreadyShippedWith() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(CaptureSettings.pointBudget, .standard)
        XCTAssertEqual(CaptureBudget.standard.maxPoints, 3_000_000)
    }

    func testTheCeilingRisesWithTheChoiceAndStopsAtFourMillion() {
        XCTAssertLessThan(CaptureBudget.careful.maxPoints, CaptureBudget.standard.maxPoints)
        XCTAssertLessThan(CaptureBudget.standard.maxPoints, CaptureBudget.high.maxPoints)
        // The user's own bar: their phone handles 4 M, and nothing should ask for
        // more than a phone was measured to hold.
        XCTAssertEqual(CaptureBudget.high.maxPoints, 4_000_000)
        for budget in CaptureBudget.allCases {
            XCTAssertLessThanOrEqual(budget.maxPoints, 4_000_000, "\(budget.rawValue) is over the bar")
            XCTAssertFalse(budget.detailLine.isEmpty, "\(budget.rawValue) does not explain itself")
        }
    }

    /// Every subject and every detail tier honours the choice — a ceiling that
    /// only some paths respected would be worse than none.
    func testEveryProfileTakesTheChosenBudget() {
        for budget in CaptureBudget.allCases {
            UserDefaults.standard.set(budget.rawValue, forKey: key)
            for subject in CaptureSubject.allCases {
                for detail in CaptureDetail.allCases {
                    let config = CaptureProfile(subject: subject, detail: detail).scanConfig()
                    XCTAssertEqual(config.maxPoints, budget.maxPoints,
                                   "\(subject.rawValue) × \(detail.rawValue) at \(budget.rawValue)")
                }
            }
        }
    }

    func testAnUnknownStoredValueFallsBackToStandard() {
        UserDefaults.standard.set("Enormous", forKey: key)
        XCTAssertEqual(CaptureSettings.pointBudget, .standard)
    }
}
