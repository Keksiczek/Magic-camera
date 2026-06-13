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

    /// Delivered on the main actor (see `report(_:)`) — it drives @Observable UI.
    /// Lock-guarded because it's assigned on main (view-model init) but read on
    /// `sessionQueue` inside `report(_:)`.
    var statusHandler: (@MainActor (DepthSessionStatus) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return _statusHandler }
        set { handlerLock.lock(); _statusHandler = newValue; handlerLock.unlock() }
    }
    private let handlerLock = NSLock()
    private var _statusHandler: (@MainActor (DepthSessionStatus) -> Void)?

    private let frameLock = NSLock()
    private var latestFrame: ARFrame?
    /// ARFrames are delivered here, not on main. At 60 fps the delegate dispatch
    /// + frame retention on the main thread competes with SwiftUI/Metal;
    /// consumers pull the latest frame through `frameLock`, so nothing depends on
    /// main-thread delivery — only `statusHandler` (which drives @Observable UI)
    /// is hopped back to main, in `report(_:)`.
    private let sessionQueue = DispatchQueue(label: "com.keks.MagicCamera.depthSession",
                                             qos: .userInitiated)

    var currentFrame: ARFrame? {
        frameLock.lock(); defer { frameLock.unlock() }
        return latestFrame
    }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = sessionQueue
    }

    var isSupported: Bool { DeviceCapabilities.supportsSceneDepth }

    func start() {
        guard let semantics = DeviceCapabilities.liveDepthSemantics() else {
            report(.unsupported)
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = semantics
        config.worldAlignment = .gravity
        // Let ARKit pick its default format (typically 1920×1440 @ 60 fps on Pro models).
        // Forcing the max-resolution format cuts frame rate to 30 fps and slows startup
        // without improving depth quality — the depth map is always 256×192 regardless.
        report(.initializing)
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
            report(.running)
        case .notAvailable:
            report(.limited("Tracking not available"))
        case .limited(let reason):
            report(.limited(Self.describe(reason)))
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        report(.failed(error.localizedDescription))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        report(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        report(.running)
    }

    /// Status updates drive @Observable UI state, but the delegate now fires on
    /// `sessionQueue` — hop to main so the handler mutates state on the main actor.
    private func report(_ status: DepthSessionStatus) {
        // Read the handler on the delegate queue, then hop only it + the status
        // (both Sendable) to the main actor — never `self`, which isn't Sendable.
        guard let handler = statusHandler else { return }
        Task { @MainActor in handler(status) }
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
