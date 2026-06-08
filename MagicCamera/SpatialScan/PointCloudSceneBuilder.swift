//
//  PointCloudSceneBuilder.swift
//  Magic Camera
//
//  Turns a PointCloud into an SCNGeometry of points, with selectable colour
//  modes. Used both for the live scan overlay and the result viewer.
//

import SceneKit
import simd
import UIKit

enum PointColorMode: String, CaseIterable, Identifiable {
    case rgb = "RGB"
    case height = "Height"
    case confidence = "Confidence"
    case uniform = "Solid"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .rgb:        return "photo"
        case .height:     return "arrow.up.and.down"
        case .confidence: return "checkmark.seal"
        case .uniform:    return "circle.fill"
        }
    }
}

enum PointCloudSceneBuilder {
    static func geometry(from cloud: PointCloud,
                         colorMode: PointColorMode,
                         pointSize: CGFloat) -> SCNGeometry? {
        let count = cloud.count
        guard count > 0 else { return nil }

        let positions = cloud.positions
        let vertexData = positions.withUnsafeBytes { Data($0) }
        let stride = MemoryLayout<SIMD3<Float>>.stride // 16 (padded); declared below

        let vertexSource = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)

        let colors = colorArray(for: cloud, mode: colorMode)
        let colorData = colors.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride)

        let element = SCNGeometryElement(
            data: nil, primitiveType: .point, primitiveCount: count,
            bytesPerIndex: MemoryLayout<Int32>.size)
        element.pointSize = pointSize
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = max(pointSize, 1.0)

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.white
        geometry.firstMaterial = material
        return geometry
    }

    static func node(from cloud: PointCloud,
                     colorMode: PointColorMode,
                     pointSize: CGFloat) -> SCNNode {
        let node = SCNNode()
        node.geometry = geometry(from: cloud, colorMode: colorMode, pointSize: pointSize)
        return node
    }

    // MARK: - Colour computation

    static func colorArray(for cloud: PointCloud, mode: PointColorMode) -> [SIMD3<Float>] {
        switch mode {
        case .rgb:
            return cloud.colors
        case .uniform:
            return Array(repeating: SIMD3<Float>(0.30, 0.55, 0.95), count: cloud.count)
        case .confidence:
            return cloud.confidences.map { c in
                // 0 -> red, 0.5 -> yellow, 1 -> green
                c >= 0.99 ? SIMD3<Float>(0.2, 0.9, 0.3)
                    : (c >= 0.49 ? SIMD3<Float>(0.95, 0.85, 0.2) : SIMD3<Float>(0.95, 0.3, 0.25))
            }
        case .height:
            guard let box = cloud.boundingBox() else { return cloud.colors }
            let minY = box.min.y, maxY = box.max.y
            let span = max(maxY - minY, 0.0001)
            return cloud.positions.map { p in
                heatRamp((p.y - minY) / span)
            }
        }
    }

    private static func heatRamp(_ t: Float) -> SIMD3<Float> {
        let x = min(max(t, 0), 1)
        let r = min(max(1.5 - abs(4 * x - 1.5), 0), 1)
        let g = min(max(1.5 - abs(4 * x - 2.5), 0), 1)
        let b = min(max(1.5 - abs(4 * x - 3.5), 0), 1)
        return SIMD3<Float>(r, g, b)
    }
}
