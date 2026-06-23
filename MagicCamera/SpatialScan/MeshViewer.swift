//
//  MeshViewer.swift
//  Magic Camera
//
//  Renders a captured mesh in an SCNView with free camera control, auto-orbit
//  and framing presets.
//

import SceneKit
import simd
import SwiftUI
import UIKit

struct MeshViewer: UIViewRepresentable {
    let mesh: MeshData
    /// Baked texture for this mesh — displayed instead of plain shading when
    /// the colour mode is `.shaded`.
    var textured: TexturedMesh? = nil
    var colorMode: MeshColorMode = .shaded
    var cameraMode: MeshCameraMode = .orbit
    var rulerEnabled: Bool = false
    var clipEnabled: Bool = false
    var clipHeight: Float = .greatestFiniteMagnitude
    var autoOrbit: Bool
    // First-person walk input: joystick vector (x strafe, y forward, −1…1)
    // and a sensitivity that scales both movement speed and look gain.
    var walkVector: CGSize = .zero
    var walkSensitivity: Float = 1.2
    // Placement mode: a second mesh shown as a ghost; tapping the host mesh
    // picks where its floor centre lands, `placementRotation` spins it.
    var placementMesh: MeshData? = nil
    var placementRotation: Float = 0
    @Binding var preset: CameraPreset?
    @Binding var rulerDistance: Float?
    @Binding var placementPosition: SIMD3<Float>?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor.black
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        scnView.rendersContinuously = true

        let scene = SCNScene()
        scnView.scene = scene

        let spin = SCNNode()
        scene.rootNode.addChildNode(spin)

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.001
        camera.zFar = 1000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode

        let coordinator = context.coordinator
        coordinator.scnView = scnView
        coordinator.spinNode = spin
        coordinator.cameraNode = cameraNode
        coordinator.rebuildIfNeeded(mesh: mesh, colorMode: colorMode, textured: textured)
        coordinator.apply(preset: .frame, mesh: mesh)
        coordinator.applyCameraMode(cameraMode, mesh: mesh)
        coordinator.applyOrbit(autoOrbit && cameraMode == .orbit && !rulerEnabled && !clipEnabled)

        let tap = UITapGestureRecognizer(target: coordinator,
                                         action: #selector(Coordinator.handleRulerTap(_:)))
        scnView.addGestureRecognizer(tap)
        coordinator.placementPositionBinding = $placementPosition
        return scnView
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.rebuildIfNeeded(mesh: mesh, colorMode: colorMode, textured: textured)
        coordinator.applyCameraMode(cameraMode, mesh: mesh)
        coordinator.applyClip(enabled: clipEnabled, height: clipHeight)
        coordinator.applyOrbit(autoOrbit && cameraMode == .orbit && !rulerEnabled && !clipEnabled
                               && placementMesh == nil)
        coordinator.rulerDistanceBinding = $rulerDistance
        coordinator.placementPositionBinding = $placementPosition
        coordinator.setRulerEnabled(rulerEnabled)
        coordinator.updatePlacement(mesh: placementMesh, rotation: placementRotation,
                                    position: placementPosition)
        coordinator.setWalkInput(vector: walkVector, sensitivity: walkSensitivity)
        if let preset {
            coordinator.apply(preset: preset, mesh: mesh)
            DispatchQueue.main.async { self.preset = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var scnView: SCNView?
        var spinNode: SCNNode?
        var cameraNode: SCNNode?
        private var meshNode: SCNNode?
        private var currentCount = -1
        private var currentColorMode: MeshColorMode?
        private var currentCameraMode: MeshCameraMode?
        private var currentTextureStamp = 0
        private var orbiting = false

        // 3D ruler
        var rulerDistanceBinding: Binding<Float?>?
        private var rulerEnabled = false
        private var rulerPoints: [SCNVector3] = []
        private var rulerNode = SCNNode()
        private var markerRadius: CGFloat = 0.01

        // Placement ghost
        var placementPositionBinding: Binding<SIMD3<Float>?>?
        private var ghostNode: SCNNode?
        private var ghostMeshCount = -1
        private var placementActive = false

        // First-person walk: per-frame movement + look-around pan.
        private var walkLink: CADisplayLink?
        private var walkVector = CGSize.zero
        private var walkSensitivity: Float = 1.2
        // Base walk speed (m/s) scaled to the scene size in applyCameraMode: a big
        // room walks fast enough to feel responsive, a small object slow enough not
        // to fly past. A fixed speed read as "nothing moves" in a large room.
        private var walkSpeedBase: Float = 1.1
        private var walkYaw: Float = 0
        private var walkPitch: Float = 0
        private var walkPanRecognizer: UIPanGestureRecognizer?
        // One-shot breadcrumbs so a "walk still doesn't move" report points at the
        // exact dead link in the chain (display-link tick / joystick input / look
        // pan) instead of another blind guess. Reset each time walk starts.
        private var loggedWalkTick = false
        private var loggedWalkInput = false
        private var loggedWalkLook = false

        /// CADisplayLink retains its target; this proxy breaks the cycle so
        /// the coordinator can deinit and invalidate the link. The link is
        /// scheduled on the main run loop, so a @MainActor selector is sound.
        private final class WalkLinkProxy {
            weak var coordinator: Coordinator?
            @MainActor @objc func step(_ link: CADisplayLink) {
                coordinator?.walkStep(link)
            }
        }

        func rebuildIfNeeded(mesh: MeshData, colorMode: MeshColorMode,
                             textured: TexturedMesh?) {
            // The baked texture only replaces plain shading; other colour modes
            // (classification/height/normals) still render the analysis colours.
            let activeTexture = colorMode == .shaded ? textured : nil
            let textureStamp = activeTexture?.texturePNG.count ?? 0
            guard mesh.count != currentCount || colorMode != currentColorMode
                || textureStamp != currentTextureStamp else { return }
            currentCount = mesh.count
            currentColorMode = colorMode
            currentTextureStamp = textureStamp

            let node: SCNNode
            if let activeTexture,
               let geometry = TexturedMeshExporter.geometry(from: activeTexture) {
                node = SCNNode(geometry: geometry)
            } else {
                node = MeshSceneBuilder.node(from: mesh, colorMode: colorMode)
            }
            meshNode?.removeFromParentNode()
            spinNode?.addChildNode(node)
            meshNode = node
            if let box = mesh.boundingBox() {
                markerRadius = CGFloat(max(simd_length(box.max - box.min) * 0.012, 0.004))
            }
        }

        // MARK: - 3D ruler

        func setRulerEnabled(_ enabled: Bool) {
            guard enabled != rulerEnabled else { return }
            rulerEnabled = enabled
            if !enabled { clearRuler() }
        }

        // MARK: - Placement (ghost + tap-to-place)

        /// Shows/positions the placement ghost. The ghost's vertices stay in
        /// the object's own coordinates; the node transform is the same
        /// pivot-to-tap matrix the bake uses, so what you see is what bakes.
        func updatePlacement(mesh: MeshData?, rotation: Float, position: SIMD3<Float>?) {
            guard let mesh else {
                placementActive = false
                ghostNode?.removeFromParentNode()
                ghostNode = nil
                ghostMeshCount = -1
                return
            }
            placementActive = true
            if ghostNode == nil || ghostMeshCount != mesh.count {
                ghostNode?.removeFromParentNode()
                let node = MeshSceneBuilder.node(from: mesh, colorMode: .shaded)
                node.opacity = 0.55
                spinNode?.addChildNode(node)
                ghostNode = node
                ghostMeshCount = mesh.count
            }
            guard let ghostNode else { return }
            if let position {
                ghostNode.isHidden = false
                ghostNode.simdTransform = SpatialScanViewModel.placementTransform(
                    for: mesh, rotation: rotation, position: position)
            } else {
                ghostNode.isHidden = true
            }
        }

        /// Picks the placement spot: hit-test against the host mesh only (the
        /// ghost is ignored so a re-tap repositions instead of stacking).
        private func handlePlacementTap(_ gesture: UITapGestureRecognizer) {
            guard let scnView else { return }
            let location = gesture.location(in: scnView)
            let hits = scnView.hitTest(location, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            guard let hit = hits.first(where: { $0.node == meshNode }) else { return }
            Haptics.impact(.light)
            // Local coordinates: the mesh node sits at identity inside the
            // (possibly orbit-rotated) spin node, so local == mesh-data space.
            let local = hit.localCoordinates
            placementPositionBinding?.wrappedValue = SIMD3<Float>(local.x, local.y, local.z)
        }

        @objc func handleRulerTap(_ gesture: UITapGestureRecognizer) {
            if placementActive { handlePlacementTap(gesture); return }
            guard rulerEnabled, let scnView else { return }
            let location = gesture.location(in: scnView)
            let hits = scnView.hitTest(location, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue
            ])
            guard let hit = hits.first(where: { $0.node == meshNode })
                    ?? hits.first else { return }
            if rulerNode.parent == nil { scnView.scene?.rootNode.addChildNode(rulerNode) }
            if rulerPoints.count >= 2 { clearRuler() }
            rulerPoints.append(hit.worldCoordinates)
            Haptics.impact(.light)
            redrawRuler()
        }

        private func clearRuler() {
            rulerPoints.removeAll()
            rulerNode.childNodes.forEach { $0.removeFromParentNode() }
            rulerDistanceBinding?.wrappedValue = nil
        }

        private func redrawRuler() {
            rulerNode.childNodes.forEach { $0.removeFromParentNode() }
            for point in rulerPoints { rulerNode.addChildNode(markerNode(at: point)) }
            guard rulerPoints.count == 2 else { return }
            rulerNode.addChildNode(lineNode(from: rulerPoints[0], to: rulerPoints[1]))
            let a = SIMD3<Float>(rulerPoints[0].x, rulerPoints[0].y, rulerPoints[0].z)
            let b = SIMD3<Float>(rulerPoints[1].x, rulerPoints[1].y, rulerPoints[1].z)
            rulerDistanceBinding?.wrappedValue = simd_distance(a, b)
        }

        private func markerNode(at position: SCNVector3) -> SCNNode {
            let sphere = SCNSphere(radius: markerRadius)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemYellow
            material.lightingModel = .constant
            sphere.firstMaterial = material
            let node = SCNNode(geometry: sphere)
            node.position = position
            return node
        }

        private func lineNode(from a: SCNVector3, to b: SCNVector3) -> SCNNode {
            let source = SCNGeometrySource(vertices: [a, b])
            let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemYellow
            material.lightingModel = .constant
            geometry.firstMaterial = material
            return SCNNode(geometry: geometry)
        }

        func applyOrbit(_ requested: Bool) {
            let enabled = requested && !UIAccessibility.isReduceMotionEnabled
            guard enabled != orbiting, let spinNode else { return }
            orbiting = enabled
            if enabled {
                spinNode.runAction(OrbitCamera.orbitAction(), forKey: "orbit")
            } else {
                spinNode.removeAction(forKey: "orbit")
            }
        }

        func apply(preset: CameraPreset, mesh: MeshData) {
            guard let cameraNode, let scnView, let box = mesh.boundingBox() else { return }
            OrbitCamera.apply(preset: preset, cameraNode: cameraNode, scnView: scnView, box: box)
        }

        // MARK: - Cross-section clip

        /// Discards fragments above `height` (world Y) so the user can see inside.
        private static let clipModifier = """
        #pragma arguments
        float clipHeight;
        #pragma body
        float4 _worldPos = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
        if (_worldPos.y > clipHeight) { discard_fragment(); }
        """

        func applyClip(enabled: Bool, height: Float) {
            guard let material = meshNode?.geometry?.firstMaterial else { return }
            if enabled {
                if material.shaderModifiers?[.surface] != Self.clipModifier {
                    material.shaderModifiers = [.surface: Self.clipModifier]
                }
                material.setValue(NSNumber(value: height), forKey: "clipHeight")
            } else if material.shaderModifiers != nil {
                material.shaderModifiers = nil
            }
        }

        func applyCameraMode(_ mode: MeshCameraMode, mesh: MeshData) {
            guard mode != currentCameraMode,
                  let cameraNode, let scnView, let box = mesh.boundingBox() else { return }
            currentCameraMode = mode
            if mode != .orbit {
                // Fly/walk modes pair badly with the auto-orbit spin, and any
                // leftover orbit rotation would put the camera outside the
                // rotated mesh — reset to the captured world orientation.
                applyOrbit(false)
                spinNode?.transform = SCNMatrix4Identity
            }
            OrbitCamera.apply(mode: mode, cameraNode: cameraNode, scnView: scnView, box: box)
            if mode == .walk {
                let extent = box.max - box.min
                let maxExtent = max(extent.x, extent.y, extent.z, 0.3)
                walkSpeedBase = min(max(maxExtent * 0.35, 0.4), 4)
                Diagnostics.shared.log("walk", String(
                    format: "setup pos %.2f,%.2f,%.2f · extent %.1fm · speed %.2f",
                    cameraNode.simdPosition.x, cameraNode.simdPosition.y,
                    cameraNode.simdPosition.z, maxExtent, walkSpeedBase))
                startWalk()
            } else {
                stopWalk()
            }
        }

        /// Called when SwiftUI discards the view — the display link must die
        /// with it (it is the only thing keeping the proxy alive).
        func tearDown() { stopWalk() }

        // MARK: - First-person walk

        func setWalkInput(vector: CGSize, sensitivity: Float) {
            if vector != .zero && !loggedWalkInput {
                loggedWalkInput = true
                Diagnostics.shared.log("walk", String(format: "input %.2f,%.2f", vector.width, vector.height))
            }
            walkVector = vector
            walkSensitivity = max(sensitivity, 0.05)
        }

        private func startWalk() {
            guard walkLink == nil, let scnView else { return }
            walkYaw = 0
            walkPitch = 0
            loggedWalkTick = false
            loggedWalkInput = false
            loggedWalkLook = false
            Diagnostics.shared.log("walk", "start")
            let proxy = WalkLinkProxy()
            proxy.coordinator = self
            let link = CADisplayLink(target: proxy, selector: #selector(WalkLinkProxy.step(_:)))
            link.add(to: .main, forMode: .common)
            walkLink = link
            let pan = UIPanGestureRecognizer(target: self,
                                             action: #selector(handleWalkPan(_:)))
            // The delegate rejects touches that begin under the on-screen
            // joystick so dragging the stick doesn't also spin the look camera.
            pan.delegate = self
            // Added only for walk mode and removed after — a permanent extra
            // recognizer would steal touches from SceneKit's built-in camera.
            scnView.addGestureRecognizer(pan)
            walkPanRecognizer = pan
            // A look drag that starts near the screen edge otherwise triggers the
            // navigation back-swipe and kicks the user to the previous screen.
            // Suspend the interactive pop gesture while walking (restored on stop).
            navigationController(from: scnView)?.interactivePopGestureRecognizer?.isEnabled = false
        }

        private func stopWalk() {
            if let scnView {
                navigationController(from: scnView)?.interactivePopGestureRecognizer?.isEnabled = true
            }
            walkLink?.invalidate()
            walkLink = nil
            if let walkPanRecognizer { scnView?.removeGestureRecognizer(walkPanRecognizer) }
            walkPanRecognizer = nil
        }

        /// Walks the responder chain from `view` to the enclosing
        /// UINavigationController (SwiftUI's NavigationStack uses one under the
        /// hood), so walk mode can suspend its edge back-swipe.
        private func navigationController(from view: UIView?) -> UINavigationController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let nav = (current as? UIViewController)?.navigationController { return nav }
                responder = current.next
            }
            return nil
        }

        /// One movement tick: walk on the floor plane (Y locked) along the
        /// camera's flattened forward/right axes.
        fileprivate func walkStep(_ link: CADisplayLink) {
            guard let cameraNode, walkVector != .zero else { return }
            let dt = Float(min(max(link.targetTimestamp - link.timestamp, 0), 1.0 / 20))
            let front = cameraNode.simdWorldFront
            var forward = SIMD3<Float>(front.x, 0, front.z)
            // Looking near-vertical flattens forward to ~0; fall back to the full
            // camera forward so the stick still moves you.
            if simd_length(forward) < 1e-3 { forward = front }
            let len = simd_length(forward)
            guard len > 1e-4 else { return }
            forward /= len
            let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
            let step = (forward * Float(walkVector.height)
                        + right * Float(walkVector.width)) * walkSpeedBase * walkSensitivity * dt
            cameraNode.simdPosition += step
            // First actual move: log the real position delta so a "walk doesn't
            // move" report is definitive — Δ>0 means the camera IS moving (so it's
            // placement/perception), Δ never logged means the step is never reached.
            if !loggedWalkTick {
                loggedWalkTick = true
                let p = cameraNode.simdPosition
                Diagnostics.shared.log("walk", String(format: "move Δ%.4fm → %.2f,%.2f,%.2f",
                    simd_length(step), p.x, p.y, p.z))
            }
        }

        @objc private func handleWalkPan(_ gesture: UIPanGestureRecognizer) {
            guard currentCameraMode == .walk, let cameraNode, let scnView else { return }
            if !loggedWalkLook {
                loggedWalkLook = true
                Diagnostics.shared.log("walk", "look pan")
            }
            let translation = gesture.translation(in: scnView)
            gesture.setTranslation(.zero, in: scnView)
            let gain = 0.0028 * min(max(walkSensitivity, 0.3), 3)
            walkYaw -= Float(translation.x) * Float(gain)
            walkPitch -= Float(translation.y) * Float(gain)
            walkPitch = min(max(walkPitch, -1.35), 1.35)
            cameraNode.simdEulerAngles = SIMD3<Float>(walkPitch, walkYaw, 0)
        }

        /// Touches that start in this left-edge strip belong to the on-screen
        /// walk joystick (a SwiftUI overlay above the SCNView). The look-around
        /// pan must ignore them — otherwise a single drag on the stick both
        /// moves *and* rotates the camera, which feels broken.
        private let joystickTouchZoneWidth: CGFloat = 150

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === walkPanRecognizer, let scnView else { return true }
            return touch.location(in: scnView).x > joystickTouchZoneWidth
        }

        // SwiftUI hosts the SCNView; without allowing simultaneous recognition its
        // gesture machinery can keep our look-pan from ever recognising — which
        // read as "can't move the camera" in walk mode. Let the pan run alongside
        // SwiftUI's / SceneKit's recognisers.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
