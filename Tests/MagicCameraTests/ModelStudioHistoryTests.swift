//
//  ModelStudioHistoryTests.swift
//  MagicCameraTests
//
//  The first view-model-level tests in the project (roadmap Tier 3). They pin the
//  undo/redo timeline in Model Studio, which is easy to get subtly wrong: the
//  classic bug is a redo stack that survives a new edit and then pastes an
//  unrelated stage over fresh work.
//

import XCTest
@testable import MagicCamera

@MainActor
final class ModelStudioHistoryTests: XCTestCase {

    private func makeStage(_ shapes: Int) -> ModelStudioViewModel {
        let vm = ModelStudioViewModel()
        for _ in 0..<shapes { vm.addPrimitive(.box) }
        return vm
    }

    func testUndoStepsBackAndRedoStepsForward() {
        let vm = makeStage(2)
        XCTAssertEqual(vm.objects.count, 2)
        XCTAssertTrue(vm.canUndo)
        XCTAssertFalse(vm.canRedo, "Nothing has been undone yet")

        vm.undo()
        XCTAssertEqual(vm.objects.count, 1)
        XCTAssertTrue(vm.canRedo)

        vm.redo()
        XCTAssertEqual(vm.objects.count, 2)
        XCTAssertFalse(vm.canRedo, "The timeline is back at its tip")
    }

    func testRedoIsUnavailableUntilSomethingIsUndone() {
        let vm = makeStage(1)
        XCTAssertFalse(vm.canRedo)
        vm.redo()
        XCTAssertEqual(vm.objects.count, 1, "Redo with an empty stack must be a no-op")
    }

    /// The invariant that makes redo safe: a new edit forks the timeline, so the
    /// undone branch must become unreachable rather than replayable on top of it.
    func testANewEditDiscardsTheRedoBranch() {
        let vm = makeStage(2)
        vm.undo()
        XCTAssertTrue(vm.canRedo)

        vm.addPrimitive(.sphere)
        XCTAssertFalse(vm.canRedo, "A fresh edit must clear the redo stack")

        vm.redo()
        XCTAssertEqual(vm.objects.count, 2, "Redo must not resurrect the abandoned branch")
        XCTAssertTrue(vm.objects.contains { $0.name.hasPrefix("Sphere") })
    }

    func testUndoRestoresObjectsWithFreshRevisions() {
        let vm = makeStage(2)
        let revisionsBefore = vm.objects.map(\.revision)
        vm.undo()
        vm.redo()
        // The renderer keys its node cache on `revision`; a restored snapshot has
        // to look new or the stale cached geometry stays on screen.
        for revision in vm.objects.map(\.revision) {
            XCTAssertFalse(revisionsBefore.contains(revision),
                           "Restored objects must carry fresh revisions")
        }
    }

    func testRoundTrippingTheWholeHistoryReturnsTheOriginalStage() {
        let vm = makeStage(3)
        let names = vm.objects.map(\.name)

        while vm.canUndo { vm.undo() }
        XCTAssertTrue(vm.objects.isEmpty)

        while vm.canRedo { vm.redo() }
        XCTAssertEqual(vm.objects.map(\.name), names)
    }

    func testMemoryPressureShedsHistoryWithoutTouchingTheStage() {
        let vm = makeStage(3)
        vm.undo()
        XCTAssertTrue(vm.canRedo)
        let onStage = vm.objects.map(\.name)

        vm.respondToMemoryPressure(.warning)
        XCTAssertFalse(vm.canRedo, "Redo is the expendable half under pressure")
        XCTAssertTrue(vm.canUndo, "A warning keeps one step back")

        vm.respondToMemoryPressure(.critical)
        XCTAssertFalse(vm.canUndo)
        XCTAssertEqual(vm.objects.map(\.name), onStage,
                       "Shedding history must never change what is on the stage")
    }
}

/// The widget ⇄ app deep-link contract. Both halves live in `WidgetSharing`
/// precisely so they can be tested together; scan ids are file names, so the
/// percent-encoding round trip is the part that actually breaks.
final class WidgetDeepLinkTests: XCTestCase {

    func testScanURLRoundTripsPlainIDs() throws {
        let url = try XCTUnwrap(WidgetSharing.scanURL(id: "Kitchen.mcmesh"))
        XCTAssertEqual(url.scheme, WidgetSharing.urlScheme)
        XCTAssertEqual(url.host, "scan")
        XCTAssertEqual(WidgetSharing.scanID(from: url), "Kitchen.mcmesh")
    }

    func testScanURLRoundTripsIDsNeedingEncoding() throws {
        for id in ["Obývák 2.mcscan", "Room #3 (final).mcmesh", "a b/c.mcmesh"] {
            let url = try XCTUnwrap(WidgetSharing.scanURL(id: id))
            XCTAssertEqual(WidgetSharing.scanID(from: url), id, "Failed round trip for \(id)")
        }
    }

    func testPlainScanLinkCarriesNoID() throws {
        let url = try XCTUnwrap(URL(string: "\(WidgetSharing.urlScheme)://scan"))
        XCTAssertNil(WidgetSharing.scanID(from: url),
                     "The bare link means “start a new scan”, not “open scan ''”")
    }

    func testForeignURLsAreIgnored() throws {
        let other = try XCTUnwrap(URL(string: "https://example.com/scan/x.mcmesh"))
        XCTAssertNil(WidgetSharing.scanID(from: other))
        let gallery = try XCTUnwrap(URL(string: "\(WidgetSharing.urlScheme)://gallery"))
        XCTAssertNil(WidgetSharing.scanID(from: gallery))
    }

    func testEmptyIDMakesNoURL() {
        XCTAssertNil(WidgetSharing.scanURL(id: ""))
    }
}

/// The CSG detail tier (roadmap 2.8) — a boolean resamples its inputs, so the
/// tier is the result's detail ceiling.
final class MeshBooleanDetailTests: XCTestCase {

    func testTiersAreOrderedAndSaneAndDefaultToStandard() {
        XCTAssertLessThan(MeshBoolean.Detail.fast.resolution, MeshBoolean.Detail.standard.resolution)
        XCTAssertLessThan(MeshBoolean.Detail.standard.resolution, MeshBoolean.Detail.fine.resolution)
        // The old hard-coded constant must remain the default, so an existing
        // install's booleans keep producing what they produced before.
        XCTAssertEqual(MeshBoolean.Detail.standard.resolution, 96)
        XCTAssertEqual(MeshBoolean.Detail(rawValue: "nonsense") ?? .standard, .standard)
    }

    /// `fast` vs `standard` rather than `fast` vs `fine`: the lattice is cubic, so
    /// the extreme pair costs ~15× as much to prove the same monotonicity.
    func testFinerTiersProduceDenserResults() throws {
        let a = PrimitiveMesher.mesh(.box, size: SIMD3(0.3, 0.3, 0.3))
        let b = PrimitiveMesher.mesh(.sphere, size: SIMD3(0.2, 0.2, 0.2))
        let coarse = try XCTUnwrap(MeshBoolean.combine(a, b, operation: .union,
                                                       resolution: MeshBoolean.Detail.fast.resolution))
        let finer = try XCTUnwrap(MeshBoolean.combine(a, b, operation: .union,
                                                      resolution: MeshBoolean.Detail.standard.resolution))
        XCTAssertGreaterThan(finer.triangleCount, coarse.triangleCount)
    }
}
