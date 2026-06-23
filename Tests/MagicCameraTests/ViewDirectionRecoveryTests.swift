import XCTest
import simd
@testable import MagicCamera

/// `SpatialScanViewModel.recoverViewDirections` underpins the one-tap model's
/// Fusion-ray reconstruction: masking / isolation return a fresh cloud with no
/// index map, but they only ever *remove* points, so each kept point can be
/// matched back to its source view direction by position. These tests pin that
/// invariant (exact recovery for true subsets, safe bail-out otherwise).
final class ViewDirectionRecoveryTests: XCTestCase {
    private func makeCloud(_ positions: [SIMD3<Float>]) -> PointCloud {
        var cloud = PointCloud()
        for p in positions { cloud.append(position: p, color: .zero, confidence: 1) }
        return cloud
    }

    func testRecoversDirectionsForReorderedSubsetByPosition() {
        // Source: 5 points on a line, each with a distinct view direction.
        let positions = (0..<5).map { SIMD3<Float>(Float($0) * 0.1, 0, 0) }
        let source = makeCloud(positions)
        let directions = (0..<5).map { simd_normalize(SIMD3<Float>(0, 1, Float($0) + 1)) }

        // A pure subset keeping points 4, 0, 2 in that order — positions verbatim.
        let subset = makeCloud([positions[4], positions[0], positions[2]])
        let recovered = SpatialScanViewModel.recoverViewDirections(
            for: subset, from: source, directions: directions)

        XCTAssertEqual(recovered?.count, 3)
        XCTAssertEqual(recovered?[0], directions[4])
        XCTAssertEqual(recovered?[1], directions[0])
        XCTAssertEqual(recovered?[2], directions[2])
    }

    func testFullCloudFastPathReturnsDirectionsUnchanged() {
        let positions = (0..<4).map { SIMD3<Float>(Float($0), 0, 0) }
        let source = makeCloud(positions)
        let directions = (0..<4).map { SIMD3<Float>(0, 0, Float($0)) }

        let recovered = SpatialScanViewModel.recoverViewDirections(
            for: source, from: source, directions: directions)
        XCTAssertEqual(recovered, directions)
    }

    func testNilWhenSourceHasNoDirections() {
        let source = makeCloud([SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)])
        XCTAssertNil(SpatialScanViewModel.recoverViewDirections(
            for: source, from: source, directions: nil))
    }

    func testNilWhenDirectionCountMismatchesSource() {
        let source = makeCloud([SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)])
        // One direction for two points — not index-aligned, so unusable.
        XCTAssertNil(SpatialScanViewModel.recoverViewDirections(
            for: source, from: source, directions: [SIMD3<Float>(0, 1, 0)]))
    }

    func testNilWhenSubsetPositionsDoNotMatchSource() {
        // Positions that don't exist in the source — the subset assumption is
        // broken (e.g. a transformed cloud), so recovery bails to nil rather than
        // attaching wrong rays.
        let source = makeCloud((0..<200).map { SIMD3<Float>(Float($0) * 0.1, 0, 0) })
        let directions = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: 200)
        let moved = makeCloud((0..<50).map { SIMD3<Float>(Float($0) * 0.1 + 100, 50, 50) })

        XCTAssertNil(SpatialScanViewModel.recoverViewDirections(
            for: moved, from: source, directions: directions))
    }
}
