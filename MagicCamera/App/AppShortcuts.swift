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

struct StartObjectCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture an Object"
    static let description = IntentDescription(
        "Opens Magic Camera's Object Capture to photograph a small object into a 3D model.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.go(to: .objectCapture)
        return .result()
    }
}

struct StartRoomPlanIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a Room Plan"
    static let description = IntentDescription(
        "Opens Magic Camera's Room Plan to capture a room's floor plan and furniture.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.go(to: .roomPlan)
        return .result()
    }
}

struct OpenModelStudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Model Studio"
    static let description = IntentDescription(
        "Opens Magic Camera's Model Studio to build and edit 3D models.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.go(to: .modelStudio)
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
        AppShortcut(
            intent: StartObjectCaptureIntent(),
            phrases: [
                "Capture an object in \(.applicationName)",
                "Object capture in \(.applicationName)"
            ],
            shortTitle: "Capture Object",
            systemImageName: "cube")
        AppShortcut(
            intent: StartRoomPlanIntent(),
            phrases: [
                "Scan a room in \(.applicationName)",
                "Room plan in \(.applicationName)"
            ],
            shortTitle: "Room Plan",
            systemImageName: "square.split.bottomrightquarter")
        AppShortcut(
            intent: OpenModelStudioIntent(),
            phrases: [
                "Open \(.applicationName) Model Studio",
                "Edit a model in \(.applicationName)"
            ],
            shortTitle: "Model Studio",
            systemImageName: "square.on.circle")
    }
}
