//
//  DeviceCapabilities.swift
//  Magic Camera
//
//  Single source of truth for what the running device can actually do. The app
//  gates depth features on real ARKit capability checks and never fakes data.
//

import ARKit

enum DeviceCapabilities {
    static var supportsWorldTracking: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    static var supportsSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    static var supportsSmoothedSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    static var supportsSceneReconstruction: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static var supportsPersonSegmentation: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)
    }

    static var hasLiDAR: Bool { supportsSceneDepth }

    /// Frame semantics for the scan session (depth only).
    static func preferredDepthSemantics() -> ARConfiguration.FrameSemantics? {
        guard supportsSceneDepth else { return nil }
        var semantics: ARConfiguration.FrameSemantics = [.sceneDepth]
        if supportsSmoothedSceneDepth { semantics.insert(.smoothedSceneDepth) }
        return semantics
    }

    /// Frame semantics for the live effects session: depth plus the person
    /// segmentation matte when the combined set is actually supported.
    static func liveDepthSemantics() -> ARConfiguration.FrameSemantics? {
        guard var semantics = preferredDepthSemantics() else { return nil }
        if supportsPersonSegmentation {
            var withSegmentation = semantics
            withSegmentation.insert(.personSegmentationWithDepth)
            if ARWorldTrackingConfiguration.supportsFrameSemantics(withSegmentation) {
                semantics = withSegmentation
            }
        }
        return semantics
    }
}
