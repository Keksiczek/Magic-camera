//
//  AppShortcuts.swift
//  Magic Camera
//
//  App Intents that deep-link into a capture mode, plus the AppShortcutsProvider
//  that surfaces them to Siri and the Shortcuts app. Each intent opens the app
//  and routes through AppRouter.
//

import AppIntents

struct StartSpatialScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Spatial Scan"
    static let description = IntentDescription(
        "Opens Magic Camera and jumps straight to the 3D spatial scanner.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.go(to: .spatialScan)
        return .result()
    }
}

struct OpenLiveDepthIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Depth Camera"
    static let description = IntentDescription(
        "Opens Magic Camera's live LiDAR depth camera.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.go(to: .liveDepth)
        return .result()
    }
}

struct MagicCameraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSpatialScanIntent(),
            phrases: [
                "Start a scan in \(.applicationName)",
                "Scan with \(.applicationName)",
                "New \(.applicationName) scan"
            ],
            shortTitle: "Start Scan",
            systemImageName: "cube.transparent")
        AppShortcut(
            intent: OpenLiveDepthIntent(),
            phrases: [
                "Open \(.applicationName) depth camera",
                "Live depth in \(.applicationName)"
            ],
            shortTitle: "Depth Camera",
            systemImageName: "camera.filters")
    }
}
