//
//  ScanARView.swift
//  Magic Camera
//
//  Live scanning surface. In point mode it forwards frames to the ScanRecorder
//  and shows a throttled point overlay; in mesh mode it enables LiDAR scene
//  reconstruction, collects mesh anchors, and shows a live wireframe.
//

import ARKit
import AVFoundation
import ImageIO
import QuartzCore
import SceneKit
import simd
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
                                   meshMode: viewModel.scanKind == .mesh,
                                   sceneMesh: viewModel.captureWantsSceneMesh,
                                   planes: viewModel.captureWantsPlanes)
        context.coordinator.setShowConfidence(viewModel.scanShowConfidence)
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
        /// Point scan wants ARKit's scene mesh as a surface mask (collect anchors
        /// without drawing the overlay) and/or plane detection for cropping.
        private var wantsSceneMesh = false
        private var wantsPlanes = false
        private var lastOverlayUpdate: TimeInterval = 0
        private let overlayInterval: TimeInterval = 0.5
        // ROI projection (read on the processing queue, written on main).
        private var sharedTarget: SIMD3<Float>?
        private var sharedTargetRadius: Float = 0.6
        private var sharedViewSize: CGSize = .zero
        /// Live overlay colour mode: confidence heatmap vs RGB (read on the
        /// processing queue, written on main).
        private var sharedShowConfidence = false
        /// Last tracking state surfaced as a coaching hint, so transient repeats
        /// don't spam (written/read on the processing queue).
        private var lastTrackingHint: String?
        private var lastROIUpdate: TimeInterval = 0
        // The live preview never needs the full multi-million-point cloud; cap it
        // so rebuilding the overlay geometry stays cheap as the scan grows.
        private let overlayMaxPoints = 60_000

        private var targetNode: SCNNode?
        private var targetCenter: SIMD3<Float>?
        /// ARAnchor pinning the scan target to the physical world. The ROI was a
        /// raw world coordinate, so when ARKit drift-corrected its map mid-scan
        /// the capture sphere drifted off the subject (the "it doesn't account for
        /// me moving" feel). Anchoring lets ARKit move the target with the world;
        /// `sharedTargetAnchorID` lets the off-main session delegate match it in
        /// `frame.anchors`, and `lastAnchoredCenter` is touched only there.
        private var targetAnchor: ARAnchor?
        private var sharedTargetAnchorID: UUID?
        private var lastAnchoredCenter: SIMD3<Float>?

        // Auto-target: a one-shot saliency pass that proposes a scan target.
        private let detector = ObjectDetector()
        private var autoTargetInFlight = false

        // Live subject silhouette for targeted point scans (~1 Hz Vision).
        private var silhouetteTimer: DispatchSourceTimer?
        // Tinted mask overlay so the user sees the lifted subject, not just
        // a sphere; mapped to screen via the frame's display transform.
        private var maskLayer: CALayer?

        deinit { silhouetteTimer?.cancel() }

        @MainActor
        init(viewModel: SpatialScanViewModel) {
            self.viewModel = viewModel
            self.recorder = viewModel.recorder
            self.meshCollector = viewModel.meshCollector
        }

        // MARK: - State sync (main thread)

        @MainActor
        func update(capturing newCapturing: Bool, meshMode newMeshMode: Bool,
                    sceneMesh newSceneMesh: Bool, planes newPlanes: Bool) {
            stateLock.lock()
            let wasCapturing = capturing
            capturing = newCapturing
            meshMode = newMeshMode
            wantsSceneMesh = newSceneMesh
            wantsPlanes = newPlanes
            sharedViewSize = arView?.bounds.size ?? .zero
            stateLock.unlock()

            if newCapturing && !wasCapturing {
                overlayNode.geometry = nil
                runSession(meshEnabled: newMeshMode,
                           sceneMesh: newSceneMesh, planes: newPlanes)
                // Lock exposure/white balance while scanning: the AE state has
                // settled during the preview, and freezing it keeps the fused
                // point colours and texture keyframes consistent across the
                // whole sweep (no visible exposure seams in the baked atlas).
                // Mesh scans capture keyframes now, so they lock too.
                setCameraLocked(true)
            } else if !newCapturing && wasCapturing {
                setCameraLocked(false)
            }
        }

        /// Switches the live point overlay between the confidence heatmap and RGB.
        @MainActor
        func setShowConfidence(_ on: Bool) {
            stateLock.lock()
            sharedShowConfidence = on
            stateLock.unlock()
        }

        /// Locks / restores auto exposure + white balance on the ARKit camera.
        @MainActor
        private func setCameraLocked(_ locked: Bool) {
            guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
                  (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if locked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
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
        private func runSession(meshEnabled: Bool, sceneMesh: Bool = false, planes: Bool = false) {
            guard let semantics = DeviceCapabilities.preferredDepthSemantics() else { return }
            let config = ARWorldTrackingConfiguration()
            config.frameSemantics = semantics
            config.worldAlignment = .gravity
            // Mesh mode renders the live surface; a point scan can also ask for
            // the scene mesh purely as a review-time mask. Either way prefer the
            // classified mesh when supported — the point-scan mask uses the floor
            // class to crop the support surface, and mesh mode colour-codes by it.
            if (meshEnabled || sceneMesh) && DeviceCapabilities.supportsSceneReconstruction {
                config.sceneReconstruction =
                    DeviceCapabilities.supportsMeshClassification ? .meshWithClassification : .mesh
            }
            // Plane detection steadies ARKit's tracking and scene-mesh quality on
            // a close subject (more anchors to lock onto); the floor itself is
            // read back from the classified mesh, not the plane anchors.
            if planes {
                config.planeDetection = [.horizontal, .vertical]
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

        // MARK: - Subject silhouette feed (targeted point scans)

        /// While a targeted point scan runs, a ~1 Hz Vision pass lifts the
        /// subject from the current frame and hands the recorder its
        /// silhouette: the ROI sphere bounds the scan, the silhouette carves
        /// the subject out of it (table edges, wall behind it, …).
        @MainActor
        private func startSilhouetteFeed() {
            guard silhouetteTimer == nil, let session = arView?.session else { return }
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "com.keks.MagicCamera.silhouette", qos: .utility))
            let sessionBox = UncheckedSendableBox(session)
            let recorder = recorder
            let selfBox = UncheckedSendableBox(self)
            // @Sendable is load-bearing: formed in a @MainActor method, a plain
            // closure would inherit main-actor isolation and trip Swift 6's
            // runtime isolation check when the timer fires on its queue.
            timer.setEventHandler { @Sendable in
                guard let frame = sessionBox.value.currentFrame,
                      case .normal = frame.camera.trackingState else { return }
                guard let mask = SubjectMasker.maskBitmap(pixelBuffer: frame.capturedImage) else {
                    return   // nothing lifted — keep the previous silhouette
                }
                let camera = frame.camera
                let k = camera.intrinsics
                let resolution = camera.imageResolution
                // Lock the silhouette to the tapped subject. SubjectMasker lifts
                // "the most prominent foreground", which as the user orbits can
                // jump to a different object — the recorder would then keep that
                // object and reject the real one (the "it picks another object /
                // the scan breaks" report). Only accept a lift that still covers
                // the scan target's projection; otherwise keep the last good
                // silhouette (the ROI sphere still bounds capture).
                selfBox.value.stateLock.lock()
                let lockTarget = selfBox.value.sharedTarget
                selfBox.value.stateLock.unlock()
                if let lockTarget {
                    let toCam = camera.transform.inverse * SIMD4<Float>(lockTarget, 1)
                    let depth = -toCam.z
                    if depth > 0.05 {
                        let u = toCam.x / depth * k.columns.0.x + k.columns.2.x
                        let v = -toCam.y / depth * k.columns.1.y + k.columns.2.y
                        if !mask.contains(normalizedX: u / Float(resolution.width),
                                          normalizedY: v / Float(resolution.height)) {
                            return   // lift no longer on the subject — hold the last one
                        }
                    }
                }
                recorder.setSilhouette(ScanSilhouette(
                    mask: mask,
                    worldToCamera: camera.transform.inverse,
                    fx: k.columns.0.x, fy: k.columns.1.y,
                    cx: k.columns.2.x, cy: k.columns.2.y,
                    width: Float(resolution.width), height: Float(resolution.height)))

                // Subject highlight: tint the mask and map it onto the screen
                // with the display transform of the frame it came from.
                let coordinator = selfBox.value
                coordinator.stateLock.lock()
                let viewSize = coordinator.sharedViewSize
                coordinator.stateLock.unlock()
                guard viewSize.width > 0,
                      let image = SubjectMaskOverlay.tintedImage(mask) else { return }
                let transform = frame.displayTransform(for: .portrait, viewportSize: viewSize)
                    .concatenating(CGAffineTransform(scaleX: viewSize.width, y: viewSize.height))
                let imageBox = UncheckedSendableBox(image)
                DispatchQueue.main.async {
                    selfBox.value.updateMaskLayer(image: imageBox.value, transform: transform)
                }
            }
            timer.schedule(deadline: .now() + 0.4, repeating: .milliseconds(1200))
            timer.resume()
            silhouetteTimer = timer
        }

        @MainActor
        private func stopSilhouetteFeed() {
            silhouetteTimer?.cancel()
            silhouetteTimer = nil
            recorder.setSilhouette(nil)
            maskLayer?.removeFromSuperlayer()
            maskLayer = nil
            viewModel.subjectMaskActive = false
        }

        @MainActor
        fileprivate func updateMaskLayer(image: CGImage, transform: CGAffineTransform) {
            guard silhouetteTimer != nil, let arView else { return }
            let layer: CALayer
            if let maskLayer {
                layer = maskLayer
            } else {
                layer = CALayer()
                // Unit-square bounds + zero anchor: the affine transform alone
                // maps normalized image space onto view points.
                layer.anchorPoint = .zero
                layer.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
                layer.position = .zero
                layer.magnificationFilter = .linear
                layer.zPosition = 10
                arView.layer.addSublayer(layer)
                maskLayer = layer
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // no implicit 0.25 s animations
            layer.contents = image
            layer.setAffineTransform(transform)
            CATransaction.commit()
            viewModel.subjectMaskActive = true
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
            anchorTarget(at: world)
            // Distance to the tapped subject drives Auto-Object (close → fine).
            let camera = frame.camera.transform.columns.3
            let distance = simd_distance(world, SIMD3<Float>(camera.x, camera.y, camera.z))
            viewModel.setScanTarget(world, cameraDistance: distance)
            updateTargetNode(center: world, radius: viewModel.scanTargetRadius)
        }

        @MainActor
        func applyTargetState(hasTarget: Bool, radius: Float) {
            stateLock.lock()
            sharedTarget = hasTarget ? targetCenter : nil
            sharedTargetRadius = radius
            stateLock.unlock()
            // The silhouette feed lives with the target, not the scan: the
            // subject highlight already shows while aiming, and the recorder
            // filter is simply ready the moment capture starts.
            if hasTarget, !state.meshMode {
                startSilhouetteFeed()
            } else if !hasTarget {
                stopSilhouetteFeed()
            }
            guard hasTarget, let center = targetCenter else {
                targetNode?.removeFromParentNode()
                targetNode = nil
                if !hasTarget {
                    targetCenter = nil
                    removeTargetAnchor()
                }
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

        /// Pins the scan target to the physical world with an ARAnchor so ARKit's
        /// drift corrections carry the ROI with the subject. Replaces any prior
        /// anchor; publishes the id for the session delegate to track.
        @MainActor
        private func anchorTarget(at world: SIMD3<Float>) {
            removeTargetAnchor()
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4<Float>(world, 1)
            let anchor = ARAnchor(name: "scanTarget", transform: transform)
            targetAnchor = anchor
            arView?.session.add(anchor: anchor)
            stateLock.lock()
            sharedTargetAnchorID = anchor.identifier
            stateLock.unlock()
        }

        @MainActor
        private func removeTargetAnchor() {
            if let anchor = targetAnchor {
                arView?.session.remove(anchor: anchor)
                targetAnchor = nil
            }
            stateLock.lock()
            sharedTargetAnchorID = nil
            stateLock.unlock()
        }

        /// Follows the target's ARAnchor as ARKit refines its world map: the
        /// capture region and ROI overlay re-centre on the corrected anchor
        /// position so they stay pinned to the physical subject instead of the
        /// stale coordinate it was first tapped at. Runs on the session delegate
        /// queue; the 3-D wireframe sphere stays put (cosmetic, sub-cm on a short
        /// scan) so this never has to hop to the main actor.
        private func updateROIFromAnchor(frame: ARFrame) {
            stateLock.lock()
            let anchorID = sharedTargetAnchorID
            let radius = sharedTargetRadius
            stateLock.unlock()
            guard let anchorID,
                  let anchor = frame.anchors.first(where: { $0.identifier == anchorID })
            else { return }
            let c = anchor.transform.columns.3
            let center = SIMD3<Float>(c.x, c.y, c.z)
            // Skip sub-millimetre jitter so we don't churn the recorder queue.
            if let last = lastAnchoredCenter, simd_distance_squared(last, center) < 1e-6 { return }
            lastAnchoredCenter = center
            recorder.setRegion(center: center, radius: radius)
            stateLock.lock()
            sharedTarget = center
            stateLock.unlock()
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
                // Pixel-accurate subject lift first — a tight box around the
                // actual foreground object. Objectness saliency stays as the
                // fallback when nothing lifts (low contrast, odd materials).
                let subjectBox = await Task.detached(priority: .userInitiated) {
                    SubjectMasker.subjectBox(pixelBuffer: bufferBox.value, orientation: orientation)
                }.value
                if let subjectBox,
                   selfBox.value.applyMaskTarget(box: subjectBox, frame: frameBox.value,
                                                 orientation: orientation, viewSize: viewSize) {
                    return
                }
                let raws = await Task.detached(priority: .userInitiated) {
                    detector.detect(pixelBuffer: bufferBox.value, orientation: orientation, maxResults: 6)
                }.value
                selfBox.value.applyAutoTarget(raws: raws, frame: frameBox.value,
                                              orientation: orientation, viewSize: viewSize)
            }
        }

        /// Applies a subject-mask box as the scan target: the world point comes
        /// from the box centre's depth, and the ROI radius from the box's
        /// angular span at that distance — so the sphere hugs the subject
        /// without manual slider fiddling. Returns false to let the saliency
        /// fallback have a go (e.g. no depth at the box centre).
        @MainActor
        fileprivate func applyMaskTarget(box: CGRect, frame: ARFrame,
                                         orientation: CGImagePropertyOrientation,
                                         viewSize: CGSize) -> Bool {
            guard !state.meshMode else { autoTargetInFlight = false; return true }
            let native = VisionGeometry.nativeNormalizedRect(box, orientation: orientation)
            guard let rect = DepthSampler.viewRect(forImageBox: native, frame: frame,
                                                   viewSize: viewSize) else { return false }
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            guard let world = DepthSampler.worldPoint(frame: frame, viewPoint: centre,
                                                      viewSize: viewSize) else { return false }
            autoTargetInFlight = false
            Haptics.impact(.medium)

            // Edge ray of a box spanning `span` pixels sits (span/2)/focal
            // off-axis; at the subject's distance that angle is the radius.
            let camera = frame.camera
            let resolution = camera.imageResolution
            let spanPixels = max(native.width * resolution.width,
                                 native.height * resolution.height)
            let focal = CGFloat(camera.intrinsics.columns.0.x)
            let position = camera.transform.columns.3
            let distance = simd_length(world - SIMD3<Float>(position.x, position.y, position.z))
            let radius = distance * Float(0.5 * spanPixels / focal) * 1.15
            let clamped = min(max(radius, 0.15), 1.5)

            viewModel.updateScanTargetRadius(clamped)
            targetCenter = world
            anchorTarget(at: world)
            viewModel.setScanTarget(world)
            updateTargetNode(center: world, radius: clamped)
            return true
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
                anchorTarget(at: world)
                viewModel.setScanTarget(world)
                updateTargetNode(center: world, radius: viewModel.scanTargetRadius)
                return
            }
            viewModel.showScanHint("No clear subject — tap to set a target")
        }

        // MARK: - ARSessionDelegate (point mode)

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let (isCapturing, isMesh) = state
            guard isCapturing else { return }
            if isMesh {
                // Mesh scans skip the point pipeline but still collect keyframe
                // photos, so the mesh can be photo-textured in review.
                recorder.considerKeyframe(frame: frame)
                return
            }
            recorder.process(frame: frame)
            updateROIFromAnchor(frame: frame)
            maybeUpdateOverlay(at: frame.timestamp)
            maybeUpdateROIProjection(frame: frame)
        }

        /// Coaching: surface why tracking degraded (and thus why accumulation
        /// pauses) so the user can fix it, instead of silently dropping frames.
        /// Fires on transitions only, so it doesn't spam.
        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            guard state.capturing else { return }
            let hint: String?
            switch camera.trackingState {
            case .normal, .notAvailable:
                hint = nil
            case .limited(let reason):
                switch reason {
                case .excessiveMotion:      hint = "Slow down — moving too fast"
                case .insufficientFeatures: hint = "Aim at more textured surfaces"
                case .initializing:         hint = "Hold steady — starting up"
                case .relocalizing:         hint = "Relocalising — return to a scanned spot"
                @unknown default:           hint = "Tracking limited — move slowly"
                }
            }
            stateLock.lock()
            let changed = hint != lastTrackingHint
            lastTrackingHint = hint
            stateLock.unlock()
            guard changed, let hint else { return }
            let viewModel = self.viewModel
            Task { @MainActor in viewModel.showScanHint(hint) }
        }

        /// Projects the ROI sphere into screen space (~10 Hz) so the focus
        /// overlay follows the subject as the camera moves.
        private func maybeUpdateROIProjection(frame: ARFrame) {
            stateLock.lock()
            let target = sharedTarget
            let radius = sharedTargetRadius
            let viewSize = sharedViewSize
            let due = frame.timestamp - lastROIUpdate >= 0.1
            if due { lastROIUpdate = frame.timestamp }
            stateLock.unlock()
            guard due, viewSize.width > 0 else { return }

            var circle: ROIScreenCircle?
            if let target {
                let cam = frame.camera
                let position = cam.transform.columns.3
                let forward = -SIMD3<Float>(cam.transform.columns.2.x,
                                            cam.transform.columns.2.y,
                                            cam.transform.columns.2.z)
                let toTarget = target - SIMD3<Float>(position.x, position.y, position.z)
                // Only when the target is in front of the camera.
                if simd_dot(toTarget, forward) > 0.05 {
                    let orientation = UIInterfaceOrientation.portrait
                    let center = cam.projectPoint(target, orientation: orientation,
                                                  viewportSize: viewSize)
                    let right = SIMD3<Float>(cam.transform.columns.0.x,
                                             cam.transform.columns.0.y,
                                             cam.transform.columns.0.z)
                    let edge = cam.projectPoint(target + right * radius,
                                                orientation: orientation,
                                                viewportSize: viewSize)
                    let radiusPx = hypot(edge.x - center.x, edge.y - center.y)
                    if radiusPx.isFinite, radiusPx > 4 {
                        circle = ROIScreenCircle(center: center, radius: radiusPx)
                    }
                }
            }
            let result = circle
            let viewModel = self.viewModel
            Task { @MainActor in
                if viewModel.roiScreenCircle != result { viewModel.roiScreenCircle = result }
            }
        }

        private func maybeUpdateOverlay(at time: TimeInterval) {
            stateLock.lock()
            let due = time - lastOverlayUpdate >= overlayInterval
            if due { lastOverlayUpdate = time }
            let showConfidence = sharedShowConfidence
            stateLock.unlock()
            guard due else { return }

            let cloud = recorder.overlaySnapshot(maxCount: overlayMaxPoints)
            let geometry = PointCloudSceneBuilder.geometry(
                from: cloud, colorMode: showConfidence ? .confidence : .rgb, pointSize: 5)
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
        }

        private func applyMesh(node: SCNNode, anchor: ARAnchor) {
            let (isCapturing, isMesh) = state
            guard isCapturing, let meshAnchor = anchor as? ARMeshAnchor else { return }
            // Capture the anchor's data and rebuild its wireframe immediately, so the
            // live mesh always reflects ARKit's latest geometry. A per-anchor time
            // throttle here made the mesh inconsistent: once ARKit stopped refining an
            // anchor, its final (throttled-away) update never landed, leaving the node
            // frozen on stale, patchy geometry. Each rebuild touches only this one
            // anchor's geometry, which is what kept it cheap before the throttle.
            meshCollector.update(meshAnchor)
            // A point scan only collects the mesh as a review-time mask — no
            // overlay. Mesh mode draws a light teal wireframe: it shows coverage
            // without the heavy opaque blue skin painting over the whole camera
            // feed (the skin read as "aggressively blue" and hid the subject).
            if isMesh {
                node.geometry = MeshSceneBuilder.wireframe(from: meshAnchor.geometry)
            }
        }
    }
}

/// Renders a subject MaskBitmap as a premultiplied-alpha tinted CGImage
/// (the target-sphere blue) for the on-screen highlight layer.
private enum SubjectMaskOverlay {
    static func tintedImage(_ mask: SubjectMasker.MaskBitmap) -> CGImage? {
        let width = mask.width, height = mask.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) where mask.pixels[i] != 0 {
            let o = i * 4
            pixels[o] = 34; pixels[o + 1] = 63; pixels[o + 2] = 109; pixels[o + 3] = 115
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
