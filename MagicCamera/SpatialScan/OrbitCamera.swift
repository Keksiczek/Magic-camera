//
//  OrbitCamera.swift
//  Magic Camera
//
//  Camera framing presets (shared by the SceneKit mesh viewer and the Metal
//  point-cloud viewer) plus SceneKit framing helpers.
//

import SceneKit
import simd

/// How the mesh viewer's camera is driven: orbiting the object from outside, or
/// flying first-person so the user can move inside the captured surface.
enum MeshCameraMode: String, CaseIterable, Identifiable {
    case orbit = "Orbit"
    case inside = "Inside"
    case walk = "Walk"
    var id: String { rawValue }
}

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

/// SceneKit camera helper (used by the mesh viewer).
enum OrbitCamera {
    @MainActor
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

    /// Switches between orbiting the object and flying first-person inside it.
    @MainActor
    static func apply(mode: MeshCameraMode, cameraNode: SCNNode, scnView: SCNView,
                      box: (min: SIMD3<Float>, max: SIMD3<Float>)) {
        let controller = scnView.defaultCameraController
        switch mode {
        case .orbit:
            scnView.allowsCameraControl = true
            controller.interactionMode = .orbitTurntable
            controller.inertiaEnabled = true
            apply(preset: .frame, cameraNode: cameraNode, scnView: scnView, box: box)
        case .walk:
            // First-person walkthrough: the viewer drives this camera itself
            // (joystick + look pan), so the built-in controller is off.
            scnView.allowsCameraControl = false
            // Re-assert our node as the rendered camera. While orbiting,
            // allowsCameraControl lets SceneKit drive (and can swap in) its own
            // point-of-view node; without this the joystick moved `cameraNode`
            // — confirmed in the logs — but the screen still rendered SceneKit's
            // node, so walk "did nothing".
            scnView.pointOfView = cameraNode
            let center = (box.min + box.max) * 0.5
            let eyeY = min(box.min.y + 1.55, box.max.y - 0.05)
            cameraNode.simdEulerAngles = SIMD3<Float>(0, 0, 0)
            cameraNode.simdPosition = SIMD3<Float>(center.x, eyeY, center.z)
        case .inside:
            scnView.allowsCameraControl = true
            let center = (box.min + box.max) * 0.5
            cameraNode.simdPosition = center
            cameraNode.look(at: SCNVector3(center.x, center.y, center.z - 1))
            controller.interactionMode = .fly
            // Inertia makes a pinch/dolly overshoot and fling the camera straight
            // through the surface, so the interior only flickers past. Disable it so
            // movement inside the mesh stays controlled.
            controller.inertiaEnabled = false
            controller.target = SCNVector3(center)
        }
    }

    static func orbitAction() -> SCNAction {
        .repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 22))
    }
}
