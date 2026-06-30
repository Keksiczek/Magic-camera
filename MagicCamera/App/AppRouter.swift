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
/// The cloud carries its persisted view rays (v2 .mcscan) so a reopened scan
/// rebuilds with fusion-rays instead of the est-normals fallback; nil for
/// legacy/ray-less clouds.
enum GalleryPick {
    case cloud(PointCloud, [SIMD3<Float>]?)
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

    /// A mesh handed off to Model Studio; ModelStudioView consumes it on appear
    /// and drops it onto the stage (mirror of the gallery-pick bridge, the other
    /// direction from Studio's own "Open in Spatial Scan").
    @ObservationIgnored var pendingStudioImport: GalleryPick?

    func openInModelStudio(_ pick: GalleryPick) {
        pendingStudioImport = pick
        path = [.modelStudio]
    }

    func consumeStudioImport() -> GalleryPick? {
        defer { pendingStudioImport = nil }
        return pendingStudioImport
    }
}
