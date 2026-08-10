//
//  BakeTriangleBudgetTests.swift
//  MagicCameraTests
//
//  The atlas budget and the triangle budget used to be decided independently.
//  A device room passed the fixed 900k triangle cap at 531,326 triangles, then
//  had its atlas cut from 4 pages to 1 by memory pressure, and 59% of the
//  model's texture ended up synthesised instead of photographed. These pin the
//  reconciliation.
//

import XCTest
@testable import MagicCamera

final class BakeTriangleBudgetTests: XCTestCase {

    /// The atlas cap is chosen from device RAM, so derive the expectation the
    /// same way rather than hardcoding 8192.
    private var texelsPerPage: Int {
        let cap = ProcessInfo.processInfo.physicalMemory > 7_000_000_000 ? 8192 : 6144
        return cap * cap
    }

    func testAFullPageBudgetDoesNotBiteTheFixedCap() {
        // Four pages can photograph more triangles than the CPU-time cap allows,
        // so a healthy bake is unaffected by this rule entirely.
        let budget = PhotoTextureBaker.affordableTriangleBudget(pages: 4)
        XCTAssertGreaterThan(budget, SpatialScanViewModel.photoBakeTriangleBudget,
                             "with memory to spare, the time budget stays the binding one")
    }

    func testOnePageCapsTheDeviceRoomThatCameOutMush() {
        let budget = PhotoTextureBaker.affordableTriangleBudget(pages: 1)
        XCTAssertLessThan(budget, 531_326, "the room that reported repaired 315751/531326")
        XCTAssertGreaterThanOrEqual(budget, texelsPerPage / 256)
    }

    func testTheBudgetScalesWithThePagesActuallyAffordable() {
        let one = PhotoTextureBaker.affordableTriangleBudget(pages: 1)
        let two = PhotoTextureBaker.affordableTriangleBudget(pages: 2)
        XCTAssertEqual(two, one * 2, "texels are linear in pages, so triangles are too")
    }

    func testASmallSubjectIsNeverDecimatedByThisRule() {
        // Even at the worst page budget the floor protects an object scan, whose
        // mesh is thousands of triangles and was never the problem.
        XCTAssertGreaterThanOrEqual(PhotoTextureBaker.affordableTriangleBudget(pages: 0),
                                    80_000)
        XCTAssertGreaterThanOrEqual(PhotoTextureBaker.affordableTriangleBudget(pages: 1),
                                    80_000)
    }
}
