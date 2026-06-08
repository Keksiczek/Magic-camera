//
//  ArcballCamera.swift
//  Magic Camera
//
//  Orbit camera for the Metal point-cloud viewer: yaw/pitch around a target,
//  distance for zoom, plus framing presets.
//

import simd

struct ArcballCamera {
    var target: SIMD3<Float> = .zero
    var distance: Float = 2
    var yaw: Float = 0
    var pitch: Float = 0.2
    var fov: Float = 60 * .pi / 180

    private let minPitch: Float = -1.52
    private let maxPitch: Float = 1.52
    private let minDistance: Float = 0.03

    var eye: SIMD3<Float> {
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        let dir = SIMD3<Float>(cp * sy, sp, cp * cy)
        return target + dir * distance
    }

    func viewMatrix() -> simd_float4x4 {
        Matrix4.lookAtRH(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        Matrix4.perspectiveRH(fovyRadians: fov, aspect: aspect, near: 0.01, far: 200)
    }

    mutating func rotate(dx: Float, dy: Float) {
        yaw += dx
        pitch = min(max(pitch - dy, minPitch), maxPitch)
    }

    mutating func zoom(scale: Float) {
        distance = max(distance / max(scale, 0.001), minDistance)
    }

    mutating func pan(dx: Float, dy: Float) {
        let v = viewMatrix()
        let right = SIMD3<Float>(v.columns.0.x, v.columns.1.x, v.columns.2.x)
        let up = SIMD3<Float>(v.columns.0.y, v.columns.1.y, v.columns.2.y)
        target += (-right * dx + up * dy) * distance
    }

    mutating func frame(center: SIMD3<Float>, radius: Float) {
        target = center
        distance = max(radius / sin(fov * 0.5), minDistance) * 1.1
    }

    mutating func applyPreset(_ preset: CameraPreset, center: SIMD3<Float>, radius: Float) {
        frame(center: center, radius: radius)
        switch preset {
        case .frame, .front: yaw = 0; pitch = 0.15
        case .top:           yaw = 0; pitch = 1.45
        case .side:          yaw = .pi / 2; pitch = 0.1
        }
    }
}
