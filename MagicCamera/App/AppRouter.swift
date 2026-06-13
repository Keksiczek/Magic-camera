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
    case roomPlan
    case modelStudio
}

/// A scan picked in the home gallery, waiting for Spatial Scan to open it.
enum GalleryPick {
    case cloud(PointCloud)
    case mesh(MeshData, TexturedMesh?)
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

    /// A selection made in the home gallery; SpatialScanView consumes it on
    /// appear (the gallery can't load into a view model that doesn't exist yet).
    @ObservationIgnored var pendingGalleryPick: GalleryPick?

    func openInSpatialScan(_ pick: GalleryPick) {
        pendingGalleryPick = pick
        path = [.spatialScan]
    }

    func consumeGalleryPick() -> GalleryPick? {
        defer { pendingGalleryPick = nil }
        return pendingGalleryPick
    }
}
