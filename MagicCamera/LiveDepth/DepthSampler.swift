//
//  DepthSampler.swift
//  Magic Camera
//
//  Converts an on-screen tap into a world-space point using the frame's depth
//  map + camera pose. Used by the live measuring tool.
//

import ARKit
import simd

enum DepthSampler {
    /// Tap location is in view points (origin top-left). Returns the world-space
    /// point under that pixel, or nil if there is no valid depth there.
    static func worldPoint(frame: ARFrame, viewPoint: CGPoint, viewSize: CGSize) -> SIMD3<Float>? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        guard let depthMap = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap else { return nil }

        let viewUV = simd_float3(Float(viewPoint.x / viewSize.width),
                                 Float(viewPoint.y / viewSize.height), 1)
        let display = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        let inv = display.inverted()
        let viewToImage = simd_float3x3(
            simd_float3(Float(inv.a),  Float(inv.b),  0),
            simd_float3(Float(inv.c),  Float(inv.d),  0),
            simd_float3(Float(inv.tx), Float(inv.ty), 1))
        let mapped = viewToImage * viewUV
        let imageUV = simd_float2(mapped.x / mapped.z, mapped.y / mapped.z)
        guard imageUV.x >= 0, imageUV.x <= 1, imageUV.y >= 0, imageUV.y <= 1 else { return nil }

        let dW = CVPixelBufferGetWidth(depthMap)
        let dH = CVPixelBufferGetHeight(depthMap)
        let cu = min(max(Int((imageUV.x * Float(dW)).rounded()), 0), dW - 1)
        let cv = min(max(Int((imageUV.y * Float(dH)).rounded()), 0), dH - 1)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let rowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let depth = base.assumingMemoryBound(to: Float32.self)[cv * rowStride + cu]
        guard depth > 0, depth.isFinite else { return nil }

        let imageRes = frame.camera.imageResolution
        let k = DepthMath.scaledIntrinsics(frame.camera.intrinsics,
                                           imageWidth: Float(imageRes.width), depthWidth: Float(dW))
        return DepthMath.worldPoint(u: Float(cu), v: Float(cv), depth: depth,
                                    intrinsics: k, cameraTransform: frame.camera.transform)
    }
}
