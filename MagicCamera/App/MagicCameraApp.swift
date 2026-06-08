//
//  MagicCameraApp.swift
//  Magic Camera
//
//  App entry point. Forces a dark, camera-style appearance throughout.
//

import SwiftUI

@main
struct MagicCameraApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
