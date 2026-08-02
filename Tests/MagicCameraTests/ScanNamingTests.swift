//
//  ScanNamingTests.swift
//  Magic Camera
//
//  The naming feature has one path that always runs (the deterministic name) and
//  one that only runs on iOS 26 with Apple Intelligence on. The model half cannot
//  be tested here, so what these pin is everything around it: the fallback names,
//  and the sanitiser that stands between a model-authored string and a filename.
//

import XCTest
import simd
@testable import MagicCamera

final class ScanNamingTests: XCTestCase {

    private func facts(kind: ScanFacts.Kind = .mesh, dimensions: SIMD3<Float>,
                       classes: [(name: String, share: Float)] = []) -> ScanFacts {
        ScanFacts(kind: kind, count: 10_000, dimensions: dimensions,
                  classificationShares: classes)
    }

    // MARK: - Deterministic names

    func testRoomSizedScanIsNamedARoom() {
        let name = facts(dimensions: SIMD3(4.2, 2.6, 3.1)).deterministicName
        XCTAssertTrue(name.hasPrefix("Room"), name)
    }

    /// Floor plus wall is the scan telling us what it is, regardless of size — a
    /// partially captured room can be under 3 m across.
    func testClassifiedRoomIsARoomEvenWhenSmall() {
        let name = facts(dimensions: SIMD3(2.4, 2.2, 2.0),
                         classes: [("floor", 0.4), ("wall", 0.35)]).deterministicName
        XCTAssertTrue(name.hasPrefix("Room"), name)
    }

    func testSmallScanIsAnObject() {
        let name = facts(dimensions: SIMD3(0.2, 0.3, 0.2)).deterministicName
        XCTAssertTrue(name.hasPrefix("Object"), name)
    }

    func testMidSizedScanIsALargeObject() {
        let name = facts(dimensions: SIMD3(1.4, 0.8, 0.6)).deterministicName
        XCTAssertTrue(name.hasPrefix("Large object"), name)
    }

    /// A dominant non-structural class names the scan — but wall and floor must
    /// not, or every partial room capture comes back called "Wall".
    func testDominantFurnitureClassNamesTheScan() {
        let table = facts(dimensions: SIMD3(1.2, 0.7, 0.8),
                          classes: [("table", 0.62)]).deterministicName
        XCTAssertTrue(table.hasPrefix("Table"), table)

        let wall = facts(dimensions: SIMD3(1.2, 0.7, 0.8),
                         classes: [("wall", 0.62)]).deterministicName
        XCTAssertFalse(wall.hasPrefix("Wall"), wall)
    }

    func testDegenerateScanStillGetsAName() {
        XCTAssertFalse(facts(dimensions: .zero).deterministicName.isEmpty)
        XCTAssertFalse(facts(kind: .pointCloud, dimensions: .zero).deterministicName.isEmpty)
    }

    // MARK: - Sanitising a model-authored name

    func testPathSeparatorsAndQuotesAreStripped() {
        XCTAssertEqual(ScanIntelligence.sanitizedName("“Living Room”"), "Living Room")
        XCTAssertEqual(ScanIntelligence.sanitizedName("Kitchen/Counter"), "Kitchen Counter")
        XCTAssertEqual(ScanIntelligence.sanitizedName("../../etc/passwd"), "etc passwd")
        XCTAssertEqual(ScanIntelligence.sanitizedName("Desk\nLamp"), "Desk Lamp")
    }

    func testEmptyOrPunctuationOnlyNamesAreRejected() {
        XCTAssertNil(ScanIntelligence.sanitizedName(""))
        XCTAssertNil(ScanIntelligence.sanitizedName("   "))
        XCTAssertNil(ScanIntelligence.sanitizedName("\"\""))
    }

    func testRunawayNamesAreBounded() {
        let long = ScanIntelligence.sanitizedName(String(repeating: "word ", count: 200))
        XCTAssertNotNil(long)
        XCTAssertLessThanOrEqual(long?.count ?? .max, 48)

        // A model that ignores "two to four words" is trimmed rather than obeyed.
        let wordy = ScanIntelligence.sanitizedName("One Two Three Four Five Six Seven")
        XCTAssertEqual(wordy, "One Two Three Four Five")
    }
}
