//
//  Math+Unproject.swift
//  Magic Camera
//
//  Pure geometry helpers for turning a depth-map pixel into a world-space
//  point. Kept free of ARKit/UIKit so it is unit-testable on any platform.
//

import simd

enum DepthMath {
    /// Scale a camera intrinsics matrix (defined for `imageSize`) down to the
    /// resolution of the depth map. ARKit intrinsics correspond to
    /// `frame.camera.imageResolution`; the depth map is lower-res but aligned.
    static func scaledIntrinsics(_ k: simd_float3x3,
                                 imageWidth: Float,
                                 depthWidth: Float) -> simd_float3x3 {
        let s = depthWidth / imageWidth
        var scaled = k
        scaled[0][0] *= s   // fx
        scaled[1][1] *= s   // fy
        scaled[2][0] *= s   // cx
        scaled[2][1] *= s   // cy
        return scaled
    }

    /// Back-project a depth-map pixel into the camera's *local* space using the
    /// ARKit convention (+x right, +y up, -z forward).
    ///
    /// - Parameters:
    ///   - u: column index in the depth map (0 ..< depthWidth). The ray passes
    ///        through the texel *centre* (u + 0.5): a texel covers [u, u+1), so
    ///        unprojecting at the integer corner skewed every point by half a
    ///        pixel (~5 mm at 2 m) toward the image origin — a systematic bias
    ///        that flipped sign between opposing sweeps and read as ghosting.
    ///   - v: row index in the depth map (0 ..< depthHeight)
    ///   - depth: metric depth in metres
    ///   - intrinsics: intrinsics already scaled to the depth-map resolution
    static func cameraLocalPoint(u: Float, v: Float, depth: Float,
                                 intrinsics k: simd_float3x3) -> simd_float3 {
        let fx = k[0][0], fy = k[1][1]
        let cx = k[2][0], cy = k[2][1]
        // Image convention: +x right, +y down, +z forward.
        let x = (u + 0.5 - cx) / fx * depth
        let y = (v + 0.5 - cy) / fy * depth
        // Convert to ARKit camera space: flip y (down->up) and z (fwd +z -> -z).
        return simd_float3(x, -y, -depth)
    }

    /// Transform a camera-local point into world space using the camera pose
    /// (`frame.camera.transform`, which is camera-to-world).
    static func worldPoint(cameraLocal: simd_float3,
                           cameraTransform: simd_float4x4) -> simd_float3 {
        let world = cameraTransform * simd_float4(cameraLocal, 1.0)
        return simd_float3(world.x, world.y, world.z)
    }

    /// Convenience: full pixel -> world in one call.
    static func worldPoint(u: Float, v: Float, depth: Float,
                           intrinsics: simd_float3x3,
                           cameraTransform: simd_float4x4) -> simd_float3 {
        let local = cameraLocalPoint(u: u, v: v, depth: depth, intrinsics: intrinsics)
        return worldPoint(cameraLocal: local, cameraTransform: cameraTransform)
    }
}
