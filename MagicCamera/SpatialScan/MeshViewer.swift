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
    var colorMode: MeshColorMode = .shaded
    var cameraMode: MeshCameraMode = .orbit
    var rulerEnabled: Bool = false
    var clipEnabled: Bool = false
    var clipHeight: Float = .greatestFiniteMagnitude
    var autoOrbit: Bool
    @Binding var preset: CameraPreset?
    @Binding var rulerDistance: Float?

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
        coordinator.rebuildIfNeeded(mesh: mesh, colorMode: colorMode)
        coordinator.apply(preset: .frame, mesh: mesh)
        coordinator.applyCameraMode(cameraMode, mesh: mesh)
        coordinator.applyOrbit(autoOrbit && cameraMode == .orbit && !rulerEnabled && !clipEnabled)

        let tap = UITapGestureRecognizer(target: coordinator,
                                         action: #selector(Coordinator.handleRulerTap(_:)))
        scnView.addGestureRecognizer(tap)
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.rebuildIfNeeded(mesh: mesh, colorMode: colorMode)
        coordinator.applyCameraMode(cameraMode, mesh: mesh)
        coordinator.applyClip(enabled: clipEnabled, height: clipHeight)
        coordinator.applyOrbit(autoOrbit && cameraMode == .orbit && !rulerEnabled && !clipEnabled)
        coordinator.rulerDistanceBinding = $rulerDistance
        coordinator.setRulerEnabled(rulerEnabled)
        if let preset {
            coordinator.apply(preset: preset, mesh: mesh)
            DispatchQueue.main.async { self.preset = nil }
        }
    }

    @MainActor
    final class Coordinator {
        weak var scnView: SCNView?
        var spinNode: SCNNode?
        var cameraNode: SCNNode?
        private var meshNode: SCNNode?
        private var currentCount = -1
        private var currentColorMode: MeshColorMode?
        private var currentCameraMode: MeshCameraMode?
        private var orbiting = false

        // 3D ruler
        var rulerDistanceBinding: Binding<Float?>?
        private var rulerEnabled = false
        private var rulerPoints: [SCNVector3] = []
        private var rulerNode = SCNNode()
        private var markerRadius: CGFloat = 0.01

        func rebuildIfNeeded(mesh: MeshData, colorMode: MeshColorMode) {
            guard mesh.count != currentCount || colorMode != currentColorMode else { return }
            currentCount = mesh.count
            currentColorMode = colorMode
            let node = MeshSceneBuilder.node(from: mesh, colorMode: colorMode)
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

        @objc func handleRulerTap(_ gesture: UITapGestureRecognizer) {
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
            if mode == .inside {
                // Inside (fly) mode pairs badly with the auto-orbit spin.
                applyOrbit(false)
                // Cancel any leftover orbit rotation so the mesh sits in its captured
                // world orientation. Otherwise the camera placed at the box centre
                // lands outside the rotated mesh and the interior never shows — it
                // just flickers as you move.
                spinNode?.transform = SCNMatrix4Identity
            }
            OrbitCamera.apply(mode: mode, cameraNode: cameraNode, scnView: scnView, box: box)
        }
    }
}
