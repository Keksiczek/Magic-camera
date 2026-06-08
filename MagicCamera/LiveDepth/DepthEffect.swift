//
//  DepthEffect.swift
//  Magic Camera
//
//  Describes the available depth effects and their tunable parameters. The
//  rendering details live in EffectRenderer / Effects.metal; this layer is the
//  data model the UI binds to and converts into GPU uniforms.
//

import simd

/// Selectable effect modes. Raw values must match `EffectType` in ShaderTypes.h.
enum DepthEffectKind: Int32, CaseIterable, Identifiable, Hashable {
    case none     = 0
    case heatmap  = 1
    case bokeh    = 2
    case outline  = 3
    case fog      = 4
    case normals  = 5
    case relight  = 6
    case portrait = 7

    var id: Int32 { rawValue }

    var title: String {
        switch self {
        case .none:     return "Raw"
        case .heatmap:  return "Heatmap"
        case .bokeh:    return "Bokeh"
        case .outline:  return "Outline"
        case .fog:      return "Fog"
        case .normals:  return "Normals"
        case .relight:  return "Relight"
        case .portrait: return "Portrait"
        }
    }

    var systemImage: String {
        switch self {
        case .none:     return "camera"
        case .heatmap:  return "thermometer.medium"
        case .bokeh:    return "camera.aperture"
        case .outline:  return "scribble.variable"
        case .fog:      return "cloud.fog"
        case .normals:  return "cube"
        case .relight:  return "lightbulb.max"
        case .portrait: return "person.crop.rectangle"
        }
    }

    var usesFocusDistance: Bool { self == .bokeh }
    var usesFogDensity: Bool { self == .fog }
    var usesDepthRange: Bool { self == .heatmap }
    var usesLightAzimuth: Bool { self == .relight }
    var usesIntensity: Bool { self != .none }
}

/// Per-frame context the renderer supplies; combined with effect parameters to
/// produce the GPU uniform struct.
struct FrameUniformContext {
    var viewToImage: simd_float3x3
    var depthTexel: simd_float2
    var depthIntrinsics: simd_float4   // fx, fy, cx, cy (depth-pixel units)
    var depthSize: simd_float2
    var hasSegmentation: Bool

    static let identity = FrameUniformContext(
        viewToImage: matrix_identity_float3x3,
        depthTexel: simd_float2(1, 1),
        depthIntrinsics: simd_float4(1, 1, 0, 0),
        depthSize: simd_float2(1, 1),
        hasSegmentation: false)
}

/// Immutable snapshot of every effect parameter.
struct EffectSettings: Equatable {
    var kind: DepthEffectKind = .heatmap
    var focusDistance: Float = 0.6
    var focusRange: Float = 0.35
    var intensity: Float = 1.0
    var fogDensity: Float = 0.45
    var depthMin: Float = 0.1
    var depthMax: Float = 4.0
    var lightAzimuth: Float = 0.0

    static let bokehMaxRadius: Float = 0.03
    static let fogColor = simd_float3(0.78, 0.82, 0.86)

    private var lightDirection: simd_float3 {
        let dir = simd_float3(0.8 * cos(lightAzimuth), 0.8 * sin(lightAzimuth), -0.6)
        return simd_normalize(dir)
    }

    func uniforms(context: FrameUniformContext) -> EffectUniforms {
        EffectUniforms(
            viewToImage: context.viewToImage,
            effect: kind.rawValue,
            focusDistance: focusDistance,
            focusRange: focusRange,
            intensity: intensity,
            fogDensity: fogDensity,
            depthMin: depthMin,
            depthMax: depthMax,
            bokehMaxRadius: EffectSettings.bokehMaxRadius,
            fogColor: EffectSettings.fogColor,
            depthTexel: context.depthTexel,
            depthIntrinsics: context.depthIntrinsics,
            depthSize: context.depthSize,
            lightDir: lightDirection,
            hasSegmentation: context.hasSegmentation ? 1 : 0
        )
    }
}
