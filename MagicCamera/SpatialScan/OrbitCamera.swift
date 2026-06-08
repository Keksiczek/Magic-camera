//
//  OrbitCamera.swift
//  Magic Camera
//
//  Shared camera-framing helper for the SceneKit-based viewers (point cloud and
//  mesh). Keeps preset framing logic in one place.
//

import SceneKit
import simd

enum OrbitCamera {
    static func apply(preset: CameraPreset, cameraNode: SCNNode, scnView: SCNView,
                      box: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        let center = (box.min + box.max) * 0.5
        let radius = max(simd_length(box.max - box.min) * 0.5, 0.1)
        let distance = radius * 2.6

        let position: SIMD3<Float>
        switch preset {
        case .frame, .front: position = center + SIMD3<Float>(0, 0, distance)
        case .top:           position = center + SIMD3<Float>(0, distance, 0.001)
        case .side:          position = center + SIMD3<Float>(distance, 0, 0)
        }

        cameraNode.simdPosition = position
        cameraNode.look(at: SCNVector3(center))
        scnView.defaultCameraController.target = SCNVector3(center)
    }

    static func orbitAction() -> SCNAction {
        .repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 22))
    }
}
