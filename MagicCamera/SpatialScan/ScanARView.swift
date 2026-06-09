//
//  ScanARView.swift
//  Magic Camera
//
//  Live scanning surface. In point mode it forwards frames to the ScanRecorder
//  and shows a throttled point overlay; in mesh mode it enables LiDAR scene
//  reconstruction, collects mesh anchors, and shows a live wireframe.
//

import ARKit
import ImageIO
import QuartzCore
import SceneKit
import SwiftUI
import UIKit

struct ScanARView: UIViewRepresentable {
    let viewModel: SpatialScanViewModel
    @Binding var autoTargetRequest: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = true
        view.scene.rootNode.addChildNode(context.coordinator.overlayNode)
        context.coordinator.arView = view
        view.delegate = context.coordinator
        view.session.delegateQueue = context.coordinator.processingQueue
        view.session.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.startPreview()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.update(capturing: viewModel.phase == .scanning,
                                   meshMode: viewModel.scanKind == .mesh)
        context.coordinator.applyTargetState(hasTarget: viewModel.hasScanTarget,
                                             radius: viewModel.scanTargetRadius)
        if autoTargetRequest {
            context.coordinator.performAutoTarget()
            DispatchQueue.main.async { autoTargetRequest = false }
        }
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate, ARSCNViewDelegate {
        private let viewModel: SpatialScanViewModel
        private let recorder: ScanRecorder
        private let meshCollector: MeshAnchorCollector
        weak var arView: ARSCNView?
        let overlayNode = SCNNode()
        let processingQueue = DispatchQueue(label: "com.keks.MagicCamera.scanProcess")

        private let stateLock = NSLock()
        private var capturing = false
        private var meshMode = false
        private var lastOverlayUpdate: TimeInterval = 0
        private let overlayInterval: TimeInterval = 0.5
        // The live preview never needs the full multi-million-point cloud; cap it
        // so rebuilding the overlay geometry stays cheap as the scan grows.
        private let overlayMaxPoints = 60_000
        // Per-anchor wireframe throttle: each anchor may refresh at most once per
        // interval. A global throttle (the previous approach) allowed only ONE anchor
        // per tick — with 30 anchors at 0.25 s each, every anchor updated only every
        // 7.5 s, making the live mesh feel frozen. Per-anchor throttle lets all
        // anchors update independently at ~4 fps each.
        private var anchorUpdateTimes: [UUID: TimeInterval] = [:]
        private let perAnchorInterval: TimeInterval = 0.20

        private var targetNode: SCNNode?
        private var targetCenter: SIMD3<Float>?

        // Auto-target: a one-shot saliency pass that proposes a scan target.
        private let detector = ObjectDetector()
        private var autoTargetInFlight = false

        @MainActor
        init(viewModel: SpatialScanViewModel) {
            self.viewModel = viewModel
            self.recorder = viewModel.recorder
            self.meshCollector = viewModel.meshCollector
        }

        // MARK: - State sync (main thread)

        @MainActor
        func update(capturing newCapturing: Bool, meshMode newMeshMode: Bool) {
            stateLock.lock()
            let wasCapturing = capturing
            capturing = newCapturing
            meshMode = newMeshMode
            if newCapturing && !wasCapturing {
                anchorUpdateTimes.removeAll()   // allow all anchors to refresh immediately
            }
            stateLock.unlock()

            if newCapturing && !wasCapturing {
                overlayNode.geometry = nil
                runSession(meshEnabled: newMeshMode)
            }
        }

        /// Runs a lightweight session so the live camera is visible before the
        /// user taps Start. Capture stays gated on `state.capturing`, so this only
        /// provides a preview; `runSession` reconfigures when capture begins.
        @MainActor
        func startPreview() {
            guard let semantics = DeviceCapabilities.preferredDepthSemantics(),
                  arView?.session.currentFrame == nil else { return }
            let config = ARWorldTrackingConfiguration()
            config.frameSemantics = semantics
            config.worldAlignment = .gravity
            arView?.session.run(config)
        }

        @MainActor
        private func runSession(meshEnabled: Bool) {
            guard let semantics = DeviceCapabilities.preferredDepthSemantics() else { return }
            let config = ARWorldTrackingConfiguration()
            config.frameSemantics = semantics
            config.worldAlignment = .gravity
            if meshEnabled && DeviceCapabilities.supportsSceneReconstruction {
                config.sceneReconstruction =
                    DeviceCapabilities.supportsMeshClassification ? .meshWithClassification : .mesh
            }
            // .removeExistingAnchors clears stale scan data from the preview session.
            // .resetTracking is intentionally omitted: the preview session already has a
            // valid tracking state, and resetting it forces a 1–3 s re-initialization pass
            // before any mesh anchors appear. Dropping it gives near-instant mesh start.
            arView?.session.run(config, options: [.removeExistingAnchors])
        }

        private var state: (capturing: Bool, meshMode: Bool) {
            stateLock.lock(); defer { stateLock.unlock() }
            return (capturing, meshMode)
        }

        // MARK: - Tap-to-target (point mode, main thread)

        @MainActor @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard !state.meshMode, let arView, let frame = arView.session.currentFrame else { return }
            let location = gesture.location(in: arView)
            guard let world = DepthSampler.worldPoint(
                frame: frame, viewPoint: location, viewSize: arView.bounds.size) else {
                viewModel.showScanHint("No depth there — aim at a surface")
                return
            }
            Haptics.impact(.medium)
            targetCenter = world
            viewModel.setScanTarget(world)
            updateTargetNode(center: world, radius: viewModel.scanTargetRadius)
        }

        @MainActor
        func applyTargetState(hasTarget: Bool, radius: Float) {
            guard hasTarget, let center = targetCenter else {
                targetNode?.removeFromParentNode()
                targetNode = nil
                if !hasTarget { targetCenter = nil }
                return
            }
            updateTargetNode(center: center, radius: radius)
        }

        @MainActor
        private func updateTargetNode(center: SIMD3<Float>, radius: Float) {
            let node = targetNode ?? makeTargetNode()
            node.simdPosition = center
            node.simdScale = SIMD3<Float>(repeating: max(radius, 0.01))
            if targetNode == nil {
                arView?.scene.rootNode.addChildNode(node)
                targetNode = node
            }
        }

        private func makeTargetNode() -> SCNNode {
            let sphere = SCNSphere(radius: 1.0)   // unit sphere, scaled to the radius
            sphere.segmentCount = 24
            let material = SCNMaterial()
            material.fillMode = .lines
            material.diffuse.contents = UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1)
            material.isDoubleSided = true
            material.lightingModel = .constant
            sphere.firstMaterial = material
            let node = SCNNode(geometry: sphere)
            node.opacity = 0.5
            return node
        }

        // MARK: - Auto-target (saliency → world point, point mode)

        @MainActor
        func performAutoTarget() {
            guard !autoTargetInFlight, !state.meshMode,
                  let arView, let frame = arView.session.currentFrame else { return }
            autoTargetInFlight = true
            viewModel.showScanHint("Looking for a subject…")

            let viewSize = arView.bounds.size
            let orientation = CameraImageOrientation.current
            let bufferBox = UncheckedSendableBox(frame.capturedImage)
            let frameBox = UncheckedSendableBox(frame)
            let detector = self.detector
            // The coordinator isn't a global-actor type, so cross the thread hop
            // via a box; the one-shot task holds it only until detection returns.
            let selfBox = UncheckedSendableBox(self)

            Task {
                let raws = await Task.detached(priority: .userInitiated) {
                    detector.detect(pixelBuffer: bufferBox.value, orientation: orientation, maxResults: 6)
                }.value
                selfBox.value.applyAutoTarget(raws: raws, frame: frameBox.value,
                                              orientation: orientation, viewSize: viewSize)
            }
        }

        @MainActor
        private func applyAutoTarget(raws: [RawDetection], frame: ARFrame,
                                     orientation: CGImagePropertyOrientation, viewSize: CGSize) {
            autoTargetInFlight = false
            guard !state.meshMode else { return }

            for raw in raws {
                let nativeBox = VisionGeometry.nativeNormalizedRect(raw.boundingBox, orientation: orientation)
                guard let rect = DepthSampler.viewRect(forImageBox: nativeBox,
                                                       frame: frame, viewSize: viewSize) else { continue }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                guard let world = DepthSampler.worldPoint(
                    frame: frame, viewPoint: center, viewSize: viewSize) else { continue }
                Haptics.impact(.medium)
                targetCenter = world
                viewModel.setScanTarget(world)
                updateTargetNode(center: world, radius: viewModel.scanTargetRadius)
                return
            }
            viewModel.showScanHint("No clear subject — tap to set a target")
        }

        // MARK: - ARSessionDelegate (point mode)

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let (isCapturing, isMesh) = state
            guard isCapturing, !isMesh else { return }
            recorder.process(frame: frame)
            maybeUpdateOverlay(at: frame.timestamp)
        }

        private func maybeUpdateOverlay(at time: TimeInterval) {
            stateLock.lock()
            let due = time - lastOverlayUpdate >= overlayInterval
            if due { lastOverlayUpdate = time }
            stateLock.unlock()
            guard due else { return }

            let cloud = recorder.overlaySnapshot(maxCount: overlayMaxPoints)
            let geometry = PointCloudSceneBuilder.geometry(from: cloud, colorMode: .rgb, pointSize: 5)
            let nodeBox = UncheckedSendableBox(overlayNode)
            let geometryBox = UncheckedSendableBox(geometry)
            DispatchQueue.main.async {
                nodeBox.value.geometry = geometryBox.value
            }
        }

        // MARK: - ARSCNViewDelegate (mesh mode)

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            applyMesh(node: node, anchor: anchor)
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            applyMesh(node: node, anchor: anchor)
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            meshCollector.remove(meshAnchor)
            stateLock.lock()
            anchorUpdateTimes.removeValue(forKey: meshAnchor.identifier)
            stateLock.unlock()
        }

        private func applyMesh(node: SCNNode, anchor: ARAnchor) {
            let (isCapturing, isMesh) = state
            guard isCapturing, isMesh, let meshAnchor = anchor as? ARMeshAnchor else { return }
            meshCollector.update(meshAnchor)
            let id = meshAnchor.identifier
            let now = CACurrentMediaTime()
            stateLock.lock()
            let due = now - (anchorUpdateTimes[id] ?? 0) >= perAnchorInterval
            if due { anchorUpdateTimes[id] = now }
            stateLock.unlock()
            guard due else { return }
            node.geometry = MeshSceneBuilder.wireframe(from: meshAnchor.geometry)
        }
    }
}
