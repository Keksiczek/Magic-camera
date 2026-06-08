//
//  VisionGeometry.swift
//  Magic Camera
//
//  Bridges Vision's oriented, normalized coordinate space back to the camera
//  buffer's native space so detections line up with the displayed image
//  regardless of which orientation Vision was asked to detect in.
//

import CoreGraphics
import ImageIO

enum VisionGeometry {
    /// Convert a Vision bounding box (normalized, bottom-left origin) reported in
    /// `orientation`-corrected space back to the original buffer's native
    /// normalized space (still bottom-left origin). Pair with ARKit's
    /// `displayTransform(.portrait)` to land it on screen.
    static func nativeNormalizedRect(_ box: CGRect,
                                     orientation: CGImagePropertyOrientation) -> CGRect {
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.maxX, y: box.maxY)
        ].map { nativePoint($0, orientation: orientation) }

        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return box }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Maps an oriented normalized point back to native normalized coordinates.
    /// Derived from how each EXIF orientation rotates the buffer to upright.
    static func nativePoint(_ p: CGPoint,
                            orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .up:    return p
        case .down:  return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .right: return CGPoint(x: 1 - p.y, y: p.x)   // native rotated 90° CW to upright
        case .left:  return CGPoint(x: p.y, y: 1 - p.x)   // native rotated 90° CCW to upright
        default:     return p   // mirrored orientations are not produced by the AR camera
        }
    }
}
