//
//  ObjectDetection.swift
//  Magic Camera
//
//  Value models for the Vision-powered object detection overlay (Mode 1).
//  Kept ARKit/Vision-free so they are Sendable and unit-testable.
//

import CoreGraphics
import Foundation
import simd

/// A raw Vision detection: normalized in the captured image's coordinate space
/// (Vision convention — origin bottom-left).
struct RawDetection: Sendable {
    let label: String
    let confidence: Float
    let boundingBox: CGRect
}

/// A detection mapped into on-screen view points, with a live depth distance.
/// `id` is derived from label + quantized position so the same physical object
/// keeps a stable identity across detection ticks (less SwiftUI churn).
struct DetectedObject: Identifiable, Sendable {
    let id: String
    let label: String
    let confidence: Float
    let screenRect: CGRect
    let distance: Float?   // metres from the camera, nil when depth is missing

    var distanceText: String? {
        guard let distance else { return nil }
        return distance < 1 ? String(format: "%.0f cm", distance * 100)
                            : String(format: "%.2f m", distance)
    }
}

/// A captured object measurement (Dimension Scanner), ready for CSV export.
struct MeasuredObject: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let distance: Float
    let size: SIMD3<Float>   // width, height, depth (metres, world-axis aligned)
    let date: Date

    var sizeText: String {
        String(format: "%.2f × %.2f × %.2f m", size.x, size.y, size.z)
    }
}
