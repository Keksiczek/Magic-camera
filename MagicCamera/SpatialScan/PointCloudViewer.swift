//
//  PointCloudViewer.swift
//  Magic Camera
//
//  Renders a captured PointCloud in an SCNView with free camera control
//  (rotate / zoom / pan), optional auto-orbit, framing presets, selectable
//  colour modes and point size.
//

import SceneKit
import simd
import SwiftUI

enum CameraPreset: String, CaseIterable, Identifiable {
    case frame, front, top, side
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .frame: return "viewfinder"
        case .front: return "rectangle.portrait"
        case .top:   return "square.split.bottomrightquarter"
        case .side:  return "cube"
        }
    }
}

struct PointCloudViewer: UIViewRepresentable {
    let cloud: PointCloud
    var colorMode: PointColorMode
    var pointSize: CGFloat
    var autoOrbit: Bool
    @Binding var preset: CameraPreset?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor.black
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
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
        coordinator.rebuildIfNeeded(cloud: cloud, colorMode: colorMode, pointSize: pointSize)
        coordinator.apply(preset: .frame, cloud: cloud)
        coordinator.applyOrbit(autoOrbit)
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.rebuildIfNeeded(cloud: cloud, colorMode: colorMode, pointSize: pointSize)
        coordinator.applyOrbit(autoOrbit)
        if let preset {
            coordinator.apply(preset: preset, cloud: cloud)
            DispatchQueue.main.async { self.preset = nil }
        }
    }

    final class Coordinator {
        weak var scnView: SCNView?
        var spinNode: SCNNode?
        var cameraNode: SCNNode?
        private var pointNode: SCNNode?

        private var currentColorMode: PointColorMode?
        private var currentPointSize: CGFloat?
        private var currentCount = -1
        private var orbiting = false

        func rebuildIfNeeded(cloud: PointCloud, colorMode: PointColorMode, pointSize: CGFloat) {
            let changed = colorMode != currentColorMode
                || pointSize != currentPointSize
                || cloud.count != currentCount
            guard changed else { return }
            currentColorMode = colorMode
            currentPointSize = pointSize
            currentCount = cloud.count

            let node = PointCloudSceneBuilder.node(from: cloud, colorMode: colorMode, pointSize: pointSize)
            pointNode?.removeFromParentNode()
            spinNode?.addChildNode(node)
            pointNode = node
        }

        func applyOrbit(_ enabled: Bool) {
            guard enabled != orbiting, let spinNode else { return }
            orbiting = enabled
            if enabled {
                spinNode.runAction(OrbitCamera.orbitAction(), forKey: "orbit")
            } else {
                spinNode.removeAction(forKey: "orbit")
            }
        }

        func apply(preset: CameraPreset, cloud: PointCloud) {
            guard let cameraNode, let scnView, let box = cloud.boundingBox() else { return }
            OrbitCamera.apply(preset: preset, cameraNode: cameraNode, scnView: scnView, box: box)
        }
    }
}
