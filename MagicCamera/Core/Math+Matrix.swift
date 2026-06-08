//
//  Math+Matrix.swift
//  Magic Camera
//
//  Right-handed view/projection matrices for the Metal point-cloud camera
//  (Metal clip space: z in 0...1).
//

import simd

enum Matrix4 {
    static func perspectiveRH(fovyRadians fovy: Float, aspect: Float,
                              near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovy * 0.5)
        let xs = ys / max(aspect, 0.0001)
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    static func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>,
                         up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)          // forward is -z
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }
}
