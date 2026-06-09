//
//  ObjectCaptureEntry.swift
//  Magic Camera
//
//  Always-compiled entry point for the RealityKit Object Capture (photogrammetry)
//  flow. The real implementation in GuidedObjectCapture.swift is device-only:
//  `ObjectCaptureSession` is absent from the simulator SDK, so it is guarded with
//  `#if !targetEnvironment(simulator)`. On the simulator (or an unsupported
//  device) this shows an explanatory placeholder instead.
//

import SwiftUI

struct ObjectCaptureEntry: View {
    // The check lives in `body` (which is @MainActor) because
    // `ObjectCaptureSession.isSupported` is main-actor isolated.
    var body: some View {
        Group {
            #if targetEnvironment(simulator)
            UnsupportedView(
                title: "Device only",
                message: "Object Capture builds a photo-real 3D model via photogrammetry. It runs only on a physical iPhone/iPad Pro with LiDAR — the API isn't available in the simulator.")
            #else
            if #available(iOS 17.0, *), ObjectCaptureSupport.isAvailable {
                GuidedObjectCaptureView()
            } else {
                UnsupportedView(
                    title: "Object Capture unavailable",
                    message: "This device doesn't support Object Capture. It needs an iPhone or iPad Pro with LiDAR running iOS 17 or later.")
            }
            #endif
        }
        .navigationTitle("Object Capture")
        .navigationBarTitleDisplayMode(.inline)
    }
}
