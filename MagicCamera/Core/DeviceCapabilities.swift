//
//  DeviceCapabilities.swift
//  Magic Camera
//
//  Single source of truth for what the running device can actually do. The app
//  gates depth features on real ARKit capability checks and never fakes data.
//

import ARKit

enum DeviceCapabilities {
    /// World tracking is the baseline for both modes.
    static var supportsWorldTracking: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// LiDAR scene depth. This is the gate for every depth effect and the scan.
    static var supportsSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// Temporally smoothed depth, nicer for live preview when available.
    static var supportsSmoothedSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    /// LiDAR mesh reconstruction (used by the capabilities report; the scan
    /// itself builds a point cloud, but this tells the user mesh is possible).
    static var supportsSceneReconstruction: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static var supportsPersonSegmentation: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth)
    }

    /// Convenience alias: a LiDAR-class device exposes scene depth.
    static var hasLiDAR: Bool { supportsSceneDepth }

    /// The frame semantics we want for a depth session, intersected with what
    /// the device supports. Returns nil if the device has no usable depth.
    static func preferredDepthSemantics() -> ARConfiguration.FrameSemantics? {
        guard supportsSceneDepth else { return nil }
        var semantics: ARConfiguration.FrameSemantics = [.sceneDepth]
        if supportsSmoothedSceneDepth { semantics.insert(.smoothedSceneDepth) }
        return semantics
    }
}
