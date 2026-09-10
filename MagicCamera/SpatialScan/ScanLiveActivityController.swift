//
//  ScanLiveActivityController.swift
//  Magic Camera
//
//  Drives the in-progress-scan Live Activity (Dynamic Island + lock screen) from
//  the scan lifecycle. The view model owns one of these and calls start / update
//  / end as the phase and live count change; the widget extension renders it (see
//  ScanActivityAttributes / ScanLiveActivity).
//
//  Every method is a safe no-op when Live Activities are unavailable or disabled
//  by the user, so callers never need to guard. ActivityKit is iOS 16.1+; the
//  deployment target is iOS 17, so no availability check is required.
//

import ActivityKit
import Foundation

@MainActor
final class ScanLiveActivityController {
    private var activity: Activity<ScanActivityAttributes>?

    /// Begins an activity for a fresh scan. Ends any previous one first so a
    /// restart can't leave two live. No-op if the user has disabled Live
    /// Activities or the request fails.
    func start(subject: String, symbol: String, phase: String, unit: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = ScanActivityAttributes(subject: subject, symbol: symbol)
        let state = ScanActivityAttributes.ContentState(phase: phase, count: 0,
                                                        progress: 0, unit: unit)
        activity = try? Activity.request(attributes: attributes,
                                         content: .init(state: state, staleDate: nil))
    }

    /// Pushes new live content. No-op when nothing is running.
    func update(phase: String, count: Int, progress: Double?, unit: String) {
        guard let activity else { return }
        let state = ScanActivityAttributes.ContentState(phase: phase, count: count,
                                                        progress: progress, unit: unit)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// Ends and dismisses the activity immediately. Idempotent.
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
