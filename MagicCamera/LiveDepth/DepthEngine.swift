//
//  DepthEngine.swift
//  Magic Camera
//
//  Owns the ARSession for the Live Depth Camera mode: configures scene depth
//  (plus the person matte when available), receives ARFrames, and exposes the
//  most recent one to the renderer. It does no rendering itself.
//

import ARKit

enum DepthSessionStatus: Equatable {
    case unsupported
    case initializing
    case running
    case limited(String)
    case interrupted
    case failed(String)
}

final class DepthEngine: NSObject, ARSessionDelegate {
    let session = ARSession()

    var statusHandler: ((DepthSessionStatus) -> Void)?

    private let frameLock = NSLock()
    private var latestFrame: ARFrame?

    var currentFrame: ARFrame? {
        frameLock.lock(); defer { frameLock.unlock() }
        return latestFrame
    }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }

    var isSupported: Bool { DeviceCapabilities.supportsSceneDepth }

    func start() {
        guard let semantics = DeviceCapabilities.liveDepthSemantics() else {
            statusHandler?(.unsupported)
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = semantics
        config.worldAlignment = .gravity
        if let best = ARWorldTrackingConfiguration.supportedVideoFormats
            .max(by: { lhs, rhs in
                lhs.imageResolution.width * lhs.imageResolution.height
                    < rhs.imageResolution.width * rhs.imageResolution.height
            }) {
            config.videoFormat = best
        }
        statusHandler?(.initializing)
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameLock.lock()
        latestFrame = frame
        frameLock.unlock()
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            statusHandler?(.running)
        case .notAvailable:
            statusHandler?(.limited("Tracking not available"))
        case .limited(let reason):
            statusHandler?(.limited(Self.describe(reason)))
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        statusHandler?(.failed(error.localizedDescription))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        statusHandler?(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        statusHandler?(.running)
    }

    private static func describe(_ reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing:         return "Initializing…"
        case .excessiveMotion:      return "Slow down — too much motion"
        case .insufficientFeatures: return "Point at a more detailed scene"
        case .relocalizing:         return "Relocalizing…"
        @unknown default:           return "Limited tracking"
        }
    }
}
