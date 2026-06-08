//
//  AppRouter.swift
//  Magic Camera
//
//  Drives programmatic navigation so App Intents / Shortcuts can deep-link into a
//  capture mode. The root NavigationStack binds to `path`; an intent sets it and
//  the app pushes the matching screen on next launch/foreground.
//

import Observation

/// The navigable destinations off the home screen.
enum AppRoute: Hashable, Sendable {
    case liveDepth
    case spatialScan
    case objectCapture
    case sensors
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var path: [AppRoute] = []

    private init() {}

    /// Replaces the stack with a single destination — used by App Intents so a
    /// shortcut always lands on a clean screen rather than stacking pushes.
    func go(to route: AppRoute) {
        path = [route]
    }
}
