//
//  CameraImageOrientation.swift
//  Magic Camera
//
//  Chooses the EXIF orientation to hand Vision so it sees an upright image,
//  based on the live device orientation (accelerometer/gyro). The UI is
//  portrait-locked, so this only improves detection accuracy — box mapping stays
//  consistent via VisionGeometry + displayTransform regardless of the choice.
//

import ImageIO
import UIKit

enum CameraImageOrientation {
    /// EXIF orientation for the rear camera given the current device orientation.
    /// Falls back to `.right` (portrait) when the orientation is unknown/flat.
    @MainActor static var current: CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:      return .up
        case .landscapeRight:     return .down
        case .portraitUpsideDown: return .left
        default:                  return .right   // portrait, faceUp/Down, unknown
        }
    }
}
