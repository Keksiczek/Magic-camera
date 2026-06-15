//
//  MagicCameraApp.swift
//  Magic Camera
//
//  App entry point. Forces a dark, camera-style appearance throughout.
//

import SwiftUI

@main
struct MagicCameraApp: App {
    init() {
        // Register MetricKit + start the breadcrumb trail as early as possible
        // so a crash or watchdog kill still leaves an exportable record.
        Diagnostics.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
