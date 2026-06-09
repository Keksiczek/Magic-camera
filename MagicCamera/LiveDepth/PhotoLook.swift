//
//  PhotoLook.swift
//  Magic Camera
//
//  One-tap photographic "looks": named tone-grade presets stacked on top of the
//  live depth preview. Each look is a curated set of the existing EffectSettings
//  grade fields (saturation / contrast / vignette / grain / temperature / tint),
//  so it layers on whatever base effect the user has chosen rather than replacing
//  it. The picker highlights the active look by matching the current settings.
//

import Foundation

enum PhotoLook: String, CaseIterable, Identifiable {
    case none
    case vivid
    case golden
    case frost
    case noir
    case bleach
    case faded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:   return "None"
        case .vivid:  return "Vivid"
        case .golden: return "Golden"
        case .frost:  return "Frost"
        case .noir:   return "Noir"
        case .bleach: return "Bleach"
        case .faded:  return "Faded"
        }
    }

    var systemImage: String {
        switch self {
        case .none:   return "circle.slash"
        case .vivid:  return "sparkles"
        case .golden: return "sun.max"
        case .frost:  return "snowflake"
        case .noir:   return "moon.stars"
        case .bleach: return "sun.haze"
        case .faded:  return "camera.filters"
        }
    }

    /// Returns a copy of `base` with this look's tone grade applied. Per-effect
    /// parameters (focus distance, fog density, light angle, …) and the chosen
    /// base effect are preserved — only the global grade fields change.
    func apply(to base: EffectSettings) -> EffectSettings {
        var s = base
        switch self {
        case .none:
            s.clearToneGrade()
        case .vivid:
            grade(&s, sat: 1.55, contrast: 1.12, vignette: 0.08, grain: 0,    temp: 0.10, tint: 0)
        case .golden:
            grade(&s, sat: 1.18, contrast: 1.05, vignette: 0.14, grain: 0.03, temp: 0.60, tint: 0.05)
        case .frost:
            grade(&s, sat: 1.04, contrast: 1.12, vignette: 0.18, grain: 0.02, temp: -0.55, tint: -0.04)
        case .noir:
            grade(&s, sat: 0,    contrast: 1.40, vignette: 0.50, grain: 0.12, temp: 0, tint: 0)
        case .bleach:
            grade(&s, sat: 0.50, contrast: 1.45, vignette: 0.30, grain: 0.07, temp: 0.08, tint: 0)
        case .faded:
            grade(&s, sat: 0.82, contrast: 0.90, vignette: 0.10, grain: 0.05, temp: 0.12, tint: 0.03)
        }
        return s
    }

    /// Best-effort match of a settings snapshot back to a named look so the UI
    /// can highlight the active chip. Returns `nil` when the grade is custom.
    static func matching(_ settings: EffectSettings) -> PhotoLook? {
        // `apply` overwrites only the grade fields, so a look matches exactly
        // when re-applying it leaves the settings unchanged.
        allCases.first { $0.apply(to: settings) == settings }
    }

    private func grade(_ s: inout EffectSettings, sat: Float, contrast: Float,
                       vignette: Float, grain: Float, temp: Float, tint: Float) {
        s.saturation = sat
        s.contrast = contrast
        s.vignette = vignette
        s.grain = grain
        s.temperature = temp
        s.tint = tint
    }
}
