//
//  ScanActivityAttributes.swift
//  Magic Camera
//
//  The data contract for the in-progress-scan Live Activity (Dynamic Island +
//  lock screen). Shared between the app — which starts, updates and ends the
//  activity from the scan lifecycle — and the widget extension, which renders
//  it. Compiled into BOTH targets (see project.yml), exactly like WidgetShared.
//
//  ActivityKit exists from iOS 16.1; the deployment target is iOS 17, so no
//  availability guard is needed here.
//

import ActivityKit
import Foundation

struct ScanActivityAttributes: ActivityAttributes {
    /// The live, changing part — pushed on each `Activity.update`.
    struct ContentState: Codable, Hashable {
        /// Short phase label, e.g. "Scanning" or "Building surface".
        var phase: String
        /// Live captured count (points, or triangles for an object mesh scan).
        var count: Int
        /// Capture progress in [0, 1] — points against the mode's cap. `nil`
        /// once capture is done (the surface build has no determinate bar).
        var progress: Double?
        /// Unit word for `count` ("pts" / "tris"), so the UI needn't guess.
        var unit: String
    }

    /// Fixed for the life of the activity.
    /// "Room" or "Object".
    var subject: String
    /// SF Symbol representing the subject.
    var symbol: String
}
