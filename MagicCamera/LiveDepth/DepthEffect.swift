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
/// The shader still carries branches for retired gimmick effects (outline,
/// fog, normals — raw values 3/4/5); they are simply no longer selectable, so
/// the remaining cases keep their explicit raw values.
enum DepthEffectKind: Int32, CaseIterable, Identifiable, Hashable {
    case none      = 0
    case heatmap   = 1
    case bokeh     = 2
    case relight   = 6
    case portrait  = 7
    case colorPop  = 8
    case depthGrade = 9

    var id: Int32 { rawValue }

    var title: String {
        switch self {
        case .none:       return "Raw"
        case .heatmap:    return "Heatmap"
        case .bokeh:      return "Bokeh"
        case .relight:    return "Relight"
        case .portrait:   return "Portrait"
        case .colorPop:   return "Color Pop"
        case .depthGrade: return "Cinematic"
        }
    }

    var systemImage: String {
        switch self {
        case .none:       return "camera"
        case .heatmap:    return "thermometer.medium"
        case .bokeh:      return "camera.aperture"
        case .relight:    return "lightbulb.max"
        case .portrait:   return "person.crop.rectangle"
        case .colorPop:   return "paintpalette"
        case .depthGrade: return "film"
        }
    }

    var usesFocusDistance: Bool { self == .bokeh }
    var usesDepthRange: Bool { self == .heatmap || self == .depthGrade }
    var usesLightDirection: Bool { self == .relight }
    var usesIntensity: Bool { self != .none }

    /// Effects that key off the person-segmentation matte (LiDAR Pro only).
    var usesPersonMatte: Bool { self == .portrait || self == .colorPop }
}

/// Per-frame context the renderer supplies; combined with effect parameters to
/// produce the GPU uniform struct.
struct FrameUniformContext {
    var viewToImage: simd_float3x3
    var depthTexel: simd_float2
    var depthIntrinsics: simd_float4   // fx, fy, cx, cy (depth-pixel units)
    var depthSize: simd_float2
    var hasSegmentation: Bool
    var grainSeed: Float = 0

    static let identity = FrameUniformContext(
        viewToImage: matrix_identity_float3x3,
        depthTexel: simd_float2(1, 1),
        depthIntrinsics: simd_float4(1, 1, 0, 0),
        depthSize: simd_float2(1, 1),
        hasSegmentation: false,
        grainSeed: 0)
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
    // Relight direction, set by dragging on the preview: angle around the
    // screen plus how frontal the light sits (centre ≈ head-on, edge ≈ grazing).
    var lightAzimuth: Float = 0.0
    var lightElevation: Float = 0.64

    // Global tone grade (applied after the chosen effect).
    var saturation: Float = 1.0
    var contrast: Float = 1.0
    var vignette: Float = 0.0
    var grain: Float = 0.0
    var temperature: Float = 0.0   // -1 cool … +1 warm
    var tint: Float = 0.0          // -1 green … +1 magenta

    static let bokehMaxRadius: Float = 0.045
    static let fogColor = simd_float3(0.78, 0.82, 0.86)

    /// True when any global tone adjustment is non-neutral.
    var hasToneGrade: Bool {
        saturation != 1 || contrast != 1 || vignette != 0 || grain != 0
            || temperature != 0 || tint != 0
    }

    /// Resets every global tone-grade field to neutral, leaving per-effect
    /// parameters (focus, fog, …) untouched.
    mutating func clearToneGrade() {
        saturation = 1; contrast = 1; vignette = 0; grain = 0
        temperature = 0; tint = 0
    }

    private var lightDirection: simd_float3 {
        // Spherical → cartesian; the default (azimuth 0, elevation 0.64) matches
        // the old fixed direction (0.8, 0, -0.6).
        let cosElevation = cos(lightElevation)
        return simd_normalize(simd_float3(cosElevation * cos(lightAzimuth),
                                          cosElevation * sin(lightAzimuth),
                                          -sin(lightElevation)))
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
            hasSegmentation: context.hasSegmentation ? 1 : 0,
            saturation: saturation,
            contrast: contrast,
            vignette: vignette,
            grain: grain,
            grainSeed: context.grainSeed,
            temperature: temperature,
            tint: tint
        )
    }
}
