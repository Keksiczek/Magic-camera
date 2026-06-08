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
    var autoOrbit: Bool
    @Binding var preset: CameraPreset?

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
        coordinator.applyOrbit(autoOrbit)
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.rebuildIfNeeded(mesh: mesh, colorMode: colorMode)
        coordinator.applyOrbit(autoOrbit)
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
        private var orbiting = false

        func rebuildIfNeeded(mesh: MeshData, colorMode: MeshColorMode) {
            guard mesh.count != currentCount || colorMode != currentColorMode else { return }
            currentCount = mesh.count
            currentColorMode = colorMode
            let node = MeshSceneBuilder.node(from: mesh, colorMode: colorMode)
            meshNode?.removeFromParentNode()
            spinNode?.addChildNode(node)
            meshNode = node
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
    }
}
