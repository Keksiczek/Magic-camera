//
//  AppSettings.swift
//  Magic Camera
//
//  Global, persisted user preferences (unit system, default scan quality) plus a
//  lightweight, isolation-free formatter that turns physical quantities into the
//  user's chosen units. Both read the same UserDefaults backing store so the
//  formatter stays correct no matter where it is called from.
//

import Foundation
import Observation
import simd

/// The unit system measurement read-outs are presented in.
enum UnitSystem: String, CaseIterable, Identifiable, Sendable {
    case metric = "Metric"
    case imperial = "Imperial"

    var id: String { rawValue }
    var detail: String { self == .metric ? "Metres · centimetres" : "Feet · inches" }
    var systemImage: String { self == .metric ? "ruler" : "ruler.fill" }
}

/// Shared UserDefaults keys so the observable store and the stateless formatter
/// never drift apart.
private enum SettingsKey {
    static let units = "settings.units"
    static let gpuTextureBake = "settings.gpuTextureBake"
    static let adaptiveReconstruction = "settings.adaptiveReconstruction"
}

/// Observable, main-actor store the Settings UI binds to. Writes through to
/// UserDefaults so preferences survive relaunches.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var units: UnitSystem {
        didSet { defaults.set(units.rawValue, forKey: SettingsKey.units) }
    }
    /// GPU-accelerated photo texture baking. On by default; a kill switch so a
    /// device-specific issue can be ruled out without a rebuild (the CPU baker
    /// stays the fallback). Read off-main via `GPUSettings`.
    var gpuTextureBake: Bool {
        didSet { defaults.set(gpuTextureBake, forKey: SettingsKey.gpuTextureBake) }
    }
    /// Experimental variable-resolution reconstruction for "Textured surface"
    /// scans — fine on detail, coarse on flat walls, with an area-proportional
    /// atlas that keeps the big surfaces sharp. Off by default while it's tuned;
    /// read off-main via `ReconstructionSettings`.
    var adaptiveReconstruction: Bool {
        didSet { defaults.set(adaptiveReconstruction, forKey: SettingsKey.adaptiveReconstruction) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        units = UnitSystem(rawValue: d.string(forKey: SettingsKey.units) ?? "") ?? .metric
        gpuTextureBake = GPUSettings.textureBakeEnabled
        adaptiveReconstruction = ReconstructionSettings.adaptiveEnabled
    }
}

/// Isolation-free read of GPU-acceleration preferences — the texture bake runs
/// on a detached task and can't touch the main-actor `AppSettings`.
enum GPUSettings {
    static var textureBakeEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: SettingsKey.gpuTextureBake) == nil
            ? true : d.bool(forKey: SettingsKey.gpuTextureBake)
    }
}

/// Isolation-free read of experimental reconstruction preferences — the surface
/// reconstruction runs on a detached task and can't touch the main-actor store.
enum ReconstructionSettings {
    /// Variable-resolution ("Textured surface") reconstruction. Off unless the
    /// user turned it on in Settings (unset defaults to false).
    static var adaptiveEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.adaptiveReconstruction)
    }
}

/// Stateless conversion of metres into the user's chosen units. Reads
/// UserDefaults directly so it is callable from any isolation context — value
/// types, view models and the photo overlay renderer all share one code path.
enum MeasurementFormat {
    private static let metresPerFoot: Float = 0.3048
    private static let metresPerInch: Float = 0.0254

    private static var units: UnitSystem {
        UnitSystem(rawValue: UserDefaults.standard.string(forKey: SettingsKey.units) ?? "") ?? .metric
    }

    /// Compact live count, e.g. "950", "12.3k", "1.20M" — short and roughly
    /// stable in width so HUD badges don't reflow as a scan grows.
    static func count(_ n: Int) -> String {
        switch n {
        case ..<1000:      return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1000)
        default:           return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }

    /// A single distance, e.g. "42 cm", "1.85 m", "7.3 in" or "5.20 ft".
    static func distance(_ metres: Float) -> String {
        switch units {
        case .metric:
            return metres < 1 ? String(format: "%.0f cm", metres * 100)
                              : String(format: "%.2f m", metres)
        case .imperial:
            let feet = metres / metresPerFoot
            return feet < 1 ? String(format: "%.1f in", metres / metresPerInch)
                            : String(format: "%.2f ft", feet)
        }
    }

    /// Width × height × depth in the major unit, e.g. "0.40 × 0.62 × 0.30 m".
    static func dimensions(_ size: SIMD3<Float>) -> String {
        switch units {
        case .metric:
            return String(format: "%.2f × %.2f × %.2f m", size.x, size.y, size.z)
        case .imperial:
            let f = size / metresPerFoot
            return String(format: "%.2f × %.2f × %.2f ft", f.x, f.y, f.z)
        }
    }

    /// Per-side labelled measurement, e.g. "W 40 cm · H 62 cm · D 30 cm" — each
    /// side formatted in unit-aware terms so small objects read in cm / inches.
    static func sides(_ size: SIMD3<Float>) -> String {
        "W \(distance(size.x)) · H \(distance(size.y)) · D \(distance(size.z))"
    }

    /// A planar area, e.g. "1.85 m²" or "19.9 ft²".
    static func area(_ squareMetres: Float) -> String {
        switch units {
        case .metric:
            return String(format: "%.2f m²", squareMetres)
        case .imperial:
            let f = squareMetres / (metresPerFoot * metresPerFoot)
            return String(format: "%.2f ft²", f)
        }
    }

    /// A volume, e.g. "320 L" / "1.85 m³" / "12.4 ft³".
    static func volume(_ cubicMetres: Float) -> String {
        switch units {
        case .metric:
            return cubicMetres < 1
                ? String(format: "%.0f L", cubicMetres * 1000)
                : String(format: "%.2f m³", cubicMetres)
        case .imperial:
            let f = cubicMetres / (metresPerFoot * metresPerFoot * metresPerFoot)
            return String(format: "%.2f ft³", f)
        }
    }
}
