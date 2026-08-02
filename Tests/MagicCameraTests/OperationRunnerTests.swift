//
//  OperationRunnerTests.swift
//  Magic Camera
//
//  `OperationRunner` is the single lifecycle every heavy job in the app runs
//  through, and it went in without an independent review. Its load-bearing claim
//  is written in a doc comment: `completion` runs exactly once on every path.
//  `perform` bridges that completion to a checked continuation, so a path that
//  skipped it would hang its caller forever and a path that ran it twice would
//  trap on a double resume. A comment is not evidence — these are.
//
//  The other property worth pinning is `cancel()` vs `requestStop()`. Conflating
//  them binned 94 s of finished, correct work on device: memory pressure asked a
//  bake to stop, the bake finished anyway, and its result was discarded as stale.
//

import XCTest
@testable import MagicCamera

/// Main-actor box so a `Task { @MainActor in … }` can report back without a
/// mutable capture (which strict concurrency rejects in a `@Sendable` closure).
/// A `@MainActor` class is implicitly `Sendable`.
@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

@MainActor
final class OperationRunnerTests: XCTestCase {

    private func makeRunner() -> OperationRunner {
        OperationRunner(category: "tests", signpostName: "test-operation")
    }

    // MARK: - completion runs exactly once, on every path

    func testSuccessCompletesOnceWithTheValue() async {
        let runner = makeRunner()
        let done = expectation(description: "completion")
        var calls = 0
        var value: Int?

        runner.run(label: "success", work: { 42 }) { result in
            calls += 1
            value = try? result.get()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        // A second call would fulfil an already-fulfilled expectation, so give any
        // stray one a chance to land before asserting.
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(value, 42)
        XCTAssertFalse(runner.isInFlight)
    }

    func testThrownErrorCompletesOnceAndIsPassedThrough() async {
        struct Boom: Error {}
        let runner = makeRunner()
        let done = expectation(description: "completion")
        var calls = 0
        var caught: Error?

        runner.run(label: "throwing", work: { () throws -> Int in throw Boom() }) { result in
            calls += 1
            if case .failure(let error) = result { caught = error }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(calls, 1)
        XCTAssertTrue(caught is Boom, "a real failure must reach the caller, not become .superseded")
        XCTAssertFalse(runner.isInFlight)
    }

    /// The path most likely to be missed: cancelled work still has to report.
    func testCancelledWorkStillCompletesExactlyOnce() async {
        let runner = makeRunner()
        let done = expectation(description: "completion")
        var calls = 0
        var failure: Error?

        runner.run(label: "cancelled", work: {
            try await Task.sleep(for: .seconds(30))
            return 1
        }) { result in
            calls += 1
            if case .failure(let error) = result { failure = error }
            done.fulfill()
        }
        // Let the detached work start before pulling it out from under itself.
        try? await Task.sleep(for: .milliseconds(50))
        runner.cancel()

        await fulfillment(of: [done], timeout: 5)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(failure as? OperationRunner.Failure, .superseded)
        XCTAssertFalse(runner.isInFlight, "cancelled work must clear the latch once it unwinds")
    }

    /// `invalidate()` bumps the generation without cancelling: the work runs to
    /// completion and its result is dropped — but the caller is still told.
    func testSupersededResultIsDiscardedButStillReported() async {
        let runner = makeRunner()
        let done = expectation(description: "completion")
        var calls = 0
        var failure: Error?

        runner.run(label: "superseded", work: {
            try await Task.sleep(for: .milliseconds(200))
            return 7
        }) { result in
            calls += 1
            if case .failure(let error) = result { failure = error }
            done.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(50))
        runner.invalidate()

        await fulfillment(of: [done], timeout: 5)
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(failure as? OperationRunner.Failure, .superseded)
    }

    // MARK: - cancel() vs requestStop()

    /// The r73 fix, pinned: `requestStop` asks the work to stop because of resource
    /// pressure, but the DATA is unchanged, so a job that finishes anyway is still
    /// valid and must be delivered. Work that ignores the cancellation flag models
    /// exactly the bake that completed 38 s after the memory-pressure stop.
    func testRequestStopKeepsAResultThatLandsAnyway() async {
        let runner = makeRunner()
        let done = expectation(description: "completion")
        var value: Int?

        runner.run(label: "stopped", work: {
            // Deliberately does not check `Task.isCancelled` — it finishes.
            try? await Task.sleep(for: .milliseconds(200))
            return 99
        }) { result in
            value = try? result.get()
            done.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(50))
        runner.requestStop()

        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(value, 99, "requestStop must not invalidate a result that lands")
    }

    func testCancelDiscardsTheSameResult() async {
        let runner = makeRunner()
        let done = expectation(description: "completion")
        var failure: Error?

        runner.run(label: "cancelled-anyway", work: {
            try? await Task.sleep(for: .milliseconds(200))
            return 99
        }) { result in
            if case .failure(let error) = result { failure = error }
            done.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(50))
        runner.cancel()

        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(failure as? OperationRunner.Failure, .superseded,
                       "cancel() means the data changed — the result is invalid even if it lands")
    }

    // MARK: - The in-flight latch

    /// `isInFlight` must stay true through cancellation until the work actually
    /// unwinds: that window is when its memory is still resident, and starting a
    /// retry inside it is how a bake cancelled for memory pressure got the app
    /// jetsam-killed by its own retry.
    func testLatchStaysUpUntilCancelledWorkUnwinds() async {
        let runner = makeRunner()
        let done = expectation(description: "completion")

        runner.run(label: "latch", work: {
            try? await Task.sleep(for: .milliseconds(250))
            return 1
        }) { _ in done.fulfill() }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(runner.isInFlight)
        runner.cancel()
        XCTAssertTrue(runner.isInFlight, "cancel() must not clear the latch — the work is still resident")

        await fulfillment(of: [done], timeout: 5)
        XCTAssertFalse(runner.isInFlight)
    }

    // MARK: - perform()

    func testPerformReturnsTheValue() async throws {
        let runner = makeRunner()
        let value = try await runner.perform(label: "perform-ok") { 5 }
        XCTAssertEqual(value, 5)
    }

    /// The reason always-once matters: a skipped completion would leave this
    /// `await` suspended forever, so the assertion is really the timeout.
    func testPerformThrowsRatherThanHangingWhenCancelled() async {
        let runner = makeRunner()
        let done = expectation(description: "perform returned")
        let thrown = Box<Error?>(nil)

        Task { @MainActor in
            do { _ = try await runner.perform(label: "perform-cancelled") {
                try await Task.sleep(for: .seconds(30))
                return 1
            } } catch { thrown.value = error }
            done.fulfill()
        }
        try? await Task.sleep(for: .milliseconds(120))
        runner.cancel()

        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(thrown.value as? OperationRunner.Failure, .superseded)
    }
}
