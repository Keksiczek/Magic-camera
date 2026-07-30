//
//  OperationRunner.swift
//  Magic Camera
//
//  The lifecycle every heavy background job in this app needs, in one place.
//
//  Three copies of it had grown: `SpatialScanViewModel.runOperation` (synchronous
//  work), `.runAsyncOperation` (an async output stream — photogrammetry), and
//  `ModelStudioViewModel.runHeavy`. They were not equivalent, and each gap cost a
//  real bug:
//
//  - Studio had no in-flight latch, so a cancelled job's memory was still live
//    when the next one started — the same shape as the bake OOM kill.
//  - Studio had no generation guard, so a result computed against an object that
//    had since moved could land and silently discard the move.
//  - Both view models released the background-task assertion only after the work
//    returned, never from the expiration handler iOS calls when time runs out.
//
//  Fixing those meant fixing them N times, and the third copy was added by the
//  very round that was cleaning the other two up. So: the mechanism lives here,
//  the POLICY stays with the caller. This type owns the cancel handle, the
//  in-flight latch, the generation counter, the background assertion and the
//  diagnostics brackets. It deliberately does NOT own "which operation is
//  running", undo snapshots, toasts or the idle timer — those differ between the
//  scan review and Studio, and folding them in is what would make this a
//  god-object instead of a runner.
//

import Foundation
import OSLog
import UIKit

@MainActor
final class OperationRunner {

    enum Failure: LocalizedError {
        /// The work returned nil — "couldn't do it", not an error with a story.
        /// The caller supplies the user-facing wording.
        case producedNothing
        /// Cancelled, or superseded by a newer job.
        case superseded

        var errorDescription: String? {
            switch self {
            case .producedNothing: return "The operation produced no result."
            case .superseded:      return "The operation was superseded."
            }
        }
    }

    private let signposter: OSSignposter
    private let log: Logger
    private let signpostName: StaticString

    /// True from the moment a job is launched until its detached task has ACTUALLY
    /// returned — which is later than the caller's own "busy" flag goes false when
    /// the job was cancelled, because cancellation only takes effect at the work's
    /// next checkpoint. Gate new work on this or a cancel-then-retry runs two jobs
    /// at once; that is how a bake cancelled for memory pressure got the app
    /// jetsam-killed by the retry.
    private(set) var isInFlight = false

    /// Bumped whenever work is cancelled or superseded. A completing job compares
    /// against the value it captured and drops a stale result.
    private(set) var generation = 0

    private var cancelHandle: (() -> Void)?

    init(subsystem: String = "com.keks.MagicCamera",
         category: String,
         signpostName: StaticString = "operation") {
        self.signposter = OSSignposter(subsystem: subsystem, category: category)
        self.log = Logger(subsystem: subsystem, category: category)
        self.signpostName = signpostName
    }

    /// Cancels the in-flight job and invalidates its result.
    ///
    /// Note what this does NOT do: clear `isInFlight`. The job is still running
    /// and still holding its memory until it reaches a checkpoint — that is
    /// exactly the window callers must not start new work in.
    func cancel() {
        generation &+= 1
        cancelHandle?()
        cancelHandle = nil
    }

    /// Asks the job to stop, but keeps its result valid if it finishes anyway.
    ///
    /// The distinction matters and cost a real result. `cancel()` bumps the
    /// generation, which guarantees the completing job's output is discarded — the
    /// right thing when the DATA changed underneath (a discard, a new scan). Memory
    /// pressure is not that: the cloud is unchanged, so a bake that manages to
    /// finish is still perfectly valid, and by the time it lands the pressure is
    /// over.
    ///
    /// The 2026-07-30 device log shows what invalidating cost: `.critical` fired
    /// 56 s into a big room's bake, and 38 s later the bake COMPLETED — `pages 2 ·
    /// 1.35 mm/texel`, textured, correct — and was thrown away as stale.
    /// `■ Building textured surface — discarded · 94354 ms`. Ninety-four seconds
    /// of work, finished, binned, and the user read it as a crash.
    func requestStop() {
        cancelHandle?()
        cancelHandle = nil
    }

    /// Invalidates any in-flight result without cancelling — for a caller that
    /// mutated the state the job was computed against.
    func invalidate() { generation &+= 1 }

    /// Runs `work` off the main actor and hands the outcome back on it.
    ///
    /// `label` names the job in the exportable breadcrumb log and the background
    /// assertion. A run the CPU watchdog kills mid-flight shows up as a `▶` with
    /// no matching `■`, which names the culprit directly in the export with no
    /// symbolication needed.
    ///
    /// `completion` runs **exactly once, on every path** — success, failure,
    /// cancellation, supersession, even the runner being deallocated. A superseded
    /// job reports `.failure(Failure.superseded)`, which callers should treat as
    /// "say nothing" (whatever bumped the generation already handled the user's
    /// intent). Always-once is not a nicety: `perform` bridges this to a
    /// continuation, and a path that skipped `completion` would hang its caller
    /// forever.
    func run<T: Sendable>(
        label: String,
        priority: TaskPriority = .utility,
        work: @Sendable @escaping () async throws -> T,
        completion: @escaping @MainActor (Result<T, Error>) -> Void
    ) {
        let crumb = Diagnostics.shared.begin(label)
        // Bracketing every heavy op is what turns "it died somewhere in the bake"
        // into a number: how much was already resident, and how much the op added.
        Diagnostics.shared.memory("\(label) start")
        let generation = self.generation
        let startedAt = Date()
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval(signpostName, id: signpostID)

        let task = Task.detached(priority: priority) { try await work() }
        cancelHandle = { task.cancel() }
        isInFlight = true

        // Keep heavy work alive across a screen-lock: the assertion buys
        // iOS-granted time so a reconstruction or bake finishes instead of being
        // suspended mid-run. Released from the expiration handler as well as the
        // normal path — iOS calls that handler when the grant is nearly up and
        // expects the release there, and a job that unwinds slowly would otherwise
        // hold an expired assertion. The handler is imported `@MainActor`
        // (`NS_SWIFT_UI_ACTOR` in UIApplication.h) while `endBackgroundTask` is
        // `NS_SWIFT_NONISOLATED`, so releasing it inside is isolation-safe; both
        // paths are on this actor, so a flag keeps it to exactly one release.
        var assertion: UIBackgroundTaskIdentifier = .invalid
        var released = false
        func release() {
            guard !released, assertion != .invalid else { return }
            released = true
            UIApplication.shared.endBackgroundTask(assertion)
        }
        assertion = UIApplication.shared.beginBackgroundTask(withName: label) {
            task.cancel()
            release()
        }

        Task { [weak self] in
            let result = await task.result
            release()
            guard let self else {
                // The runner outlived by nothing — but `completion` must still
                // fire, or a `perform` continuation leaks.
                completion(.failure(Failure.superseded))
                return
            }
            self.signposter.endInterval(self.signpostName, interval)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            // Cleared BEFORE the staleness guard: a cancelled job still reaches
            // this point once it unwinds, and that is exactly the moment its
            // memory is free and a retry becomes safe.
            self.isInFlight = false
            guard self.generation == generation else {
                Diagnostics.shared.end(crumb, "discarded")   // end() appends elapsed ms
                self.log.debug("\(label, privacy: .public) superseded after \(ms) ms")
                completion(.failure(Failure.superseded))
                return
            }
            self.cancelHandle = nil
            Diagnostics.shared.memory("\(label) end")
            switch result {
            case .success(let value):
                Diagnostics.shared.end(crumb, "ok")
                self.log.debug("\(label, privacy: .public) ok in \(ms) ms")
                completion(.success(value))
            case .failure(let error):
                let cancelled = error is CancellationError
                Diagnostics.shared.end(crumb, cancelled ? "cancelled" : "failed")
                self.log.debug("\(label, privacy: .public) \(cancelled ? "cancelled" : "failed", privacy: .public) in \(ms) ms")
                completion(.failure(cancelled ? Failure.superseded : error))
            }
        }
    }

    /// `await`-shaped sibling of `run` for callers that already sit in an async
    /// context and want the value inline (Studio's chat-driven tools). Same
    /// machinery; the caller handles the throw.
    func perform<T: Sendable>(
        label: String,
        priority: TaskPriority = .userInitiated,
        work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            run(label: label, priority: priority, work: work) { result in
                continuation.resume(with: result)
            }
        }
    }
}
