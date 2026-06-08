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

    /// Straight-line distance from the camera to the world point under a tap.
    static func distance(frame: ARFrame, viewPoint: CGPoint, viewSize: CGSize) -> Float? {
        guard let world = worldPoint(frame: frame, viewPoint: viewPoint, viewSize: viewSize) else { return nil }
        let c = frame.camera.transform.columns.3
        return simd_distance(world, SIMD3<Float>(c.x, c.y, c.z))
    }

    /// Estimate the real-world size of a screen-space region by unprojecting a
    /// grid of samples inside it and measuring the world-axis-aligned extents.
    /// Returns (distance to the region centre, width × height × depth in metres).
    static func measureRegion(frame: ARFrame, viewRect: CGRect, viewSize: CGSize,
                              grid: Int = 6) -> (distance: Float, size: SIMD3<Float>)? {
        guard viewRect.width > 0, viewRect.height > 0, grid >= 2 else { return nil }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(grid * grid)
        for i in 0..<grid {
            for j in 0..<grid {
                let x = viewRect.minX + viewRect.width * (CGFloat(i) + 0.5) / CGFloat(grid)
                let y = viewRect.minY + viewRect.height * (CGFloat(j) + 0.5) / CGFloat(grid)
                if let world = worldPoint(frame: frame, viewPoint: CGPoint(x: x, y: y), viewSize: viewSize) {
                    points.append(world)
                }
            }
        }
        guard points.count >= 4 else { return nil }
        var lo = points[0], hi = points[0]
        for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let center = (lo + hi) * 0.5
        let c = frame.camera.transform.columns.3
        let distance = simd_distance(center, SIMD3<Float>(c.x, c.y, c.z))
        return (distance, hi - lo)
    }

    /// Maps a Vision bounding box (normalized, origin bottom-left, native image
    /// space) to a rectangle in view points, matching how the camera image is
    /// presented on screen (portrait aspect-fill).
    static func viewRect(forImageBox box: CGRect, frame: ARFrame, viewSize: CGSize) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let display = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        // Vision (bottom-left) -> ARKit image normalized (top-left): flip Y.
        let corners = [
            CGPoint(x: box.minX, y: 1 - box.minY),
            CGPoint(x: box.maxX, y: 1 - box.minY),
            CGPoint(x: box.minX, y: 1 - box.maxY),
            CGPoint(x: box.maxX, y: 1 - box.maxY)
        ].map { point -> CGPoint in
            let v = point.applying(display)
            return CGPoint(x: v.x * viewSize.width, y: v.y * viewSize.height)
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
