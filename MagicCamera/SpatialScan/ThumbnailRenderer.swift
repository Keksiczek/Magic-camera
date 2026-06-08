//
//  ThumbnailRenderer.swift
//  Magic Camera
//
//  Renders a small offscreen preview of a point cloud or mesh to PNG data, used
//  for the saved-scans gallery. Uses an offscreen SCNRenderer so it never needs
//  a live view. Best-effort — returns nil if Metal/SceneKit is unavailable.
//

import SceneKit
import simd
import UIKit

@MainActor
enum ThumbnailRenderer {
    static let size = CGSize(width: 480, height: 480)

    static func png(for cloud: PointCloud) -> Data? {
        guard let box = cloud.boundingBox() else { return nil }
        let node = PointCloudSceneBuilder.node(from: cloud, colorMode: .rgb, pointSize: 7)
        return render(node: node, box: box, lit: false)
    }

    static func png(for mesh: MeshData) -> Data? {
        guard let box = mesh.boundingBox() else { return nil }
        let mode: MeshColorMode = mesh.hasClassification ? .classification : .shaded
        let node = MeshSceneBuilder.node(from: mesh, colorMode: mode)
        return render(node: node, box: box, lit: !mesh.hasClassification)
    }

    // MARK: - Offscreen render

    private static func render(node: SCNNode,
                               box: (min: SIMD3<Float>, max: SIMD3<Float>),
                               lit: Bool) -> Data? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.05, alpha: 1)
        scene.rootNode.addChildNode(node)

        let center = (box.min + box.max) * 0.5
        let radius = max(simd_length(box.max - box.min) * 0.5, 0.1)
        let distance = radius * 2.4

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.001
        camera.zFar = 1000
        cameraNode.camera = camera
        // Three-quarter view for a readable preview.
        cameraNode.simdPosition = center + SIMD3<Float>(distance * 0.7, distance * 0.6, distance * 0.7)
        cameraNode.look(at: SCNVector3(center))
        scene.rootNode.addChildNode(cameraNode)

        if lit {
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 500
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 800
            key.simdPosition = cameraNode.simdPosition
            key.look(at: SCNVector3(center))
            scene.rootNode.addChildNode(key)
        }

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image.pngData()
    }
}
