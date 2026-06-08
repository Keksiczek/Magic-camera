//
//  MeshClassification.swift
//  Magic Camera
//
//  Maps ARKit mesh face classifications (wall, floor, ceiling, …) to labels and
//  display colours, so a classified mesh can be colour-coded by surface type.
//  Raw values match `ARMeshClassification`.
//

import ARKit
import simd
import UIKit

enum MeshClassification: UInt8, CaseIterable, Identifiable {
    case none = 0
    case wall = 1
    case floor = 2
    case ceiling = 3
    case table = 4
    case seat = 5
    case window = 6
    case door = 7

    var id: UInt8 { rawValue }

    init(arValue: ARMeshClassification) {
        self = MeshClassification(rawValue: UInt8(arValue.rawValue)) ?? .none
    }

    var label: String {
        switch self {
        case .none:    return "Unclassified"
        case .wall:    return "Wall"
        case .floor:   return "Floor"
        case .ceiling: return "Ceiling"
        case .table:   return "Table"
        case .seat:    return "Seat"
        case .window:  return "Window"
        case .door:    return "Door"
        }
    }

    /// Distinct, reasonably high-contrast colour per class.
    var color: SIMD3<Float> {
        switch self {
        case .none:    return SIMD3<Float>(0.62, 0.62, 0.66)
        case .wall:    return SIMD3<Float>(0.36, 0.52, 0.92)
        case .floor:   return SIMD3<Float>(0.36, 0.78, 0.52)
        case .ceiling: return SIMD3<Float>(0.78, 0.74, 0.42)
        case .table:   return SIMD3<Float>(0.92, 0.58, 0.30)
        case .seat:    return SIMD3<Float>(0.86, 0.38, 0.55)
        case .window:  return SIMD3<Float>(0.40, 0.82, 0.86)
        case .door:    return SIMD3<Float>(0.74, 0.46, 0.90)
        }
    }

    var uiColor: UIColor {
        let c = color
        return UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }
}
