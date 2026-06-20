//
//  Theme.swift
//  Magic Camera
//
//  Centralised design tokens + reusable styles so colour, depth, motion and
//  rhythm stay consistent and intentional across the app (a premium, camera-dark
//  glass UI). Screens compose these instead of hand-rolling materials/shadows,
//  so a change here lifts the whole app at once.
//

import SwiftUI

enum Theme {
    // MARK: - Palette
    static let accent = Color(red: 0.30, green: 0.45, blue: 0.95)
    static let accentWarm = Color(red: 1.0, green: 0.55, blue: 0.30)
    static let success = Color(red: 0.30, green: 0.80, blue: 0.45)
    static let warning = Color(red: 1.0, green: 0.75, blue: 0.0)

    static let background = Color.black
    static let surface = Color.white.opacity(0.08)
    static let surfaceElevated = Color.white.opacity(0.12)
    static let surfaceStroke = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.65)
    static let textTertiary = Color.white.opacity(0.40)

    // MARK: - Radii
    static let cornerXL: CGFloat = 28
    static let cornerLarge: CGFloat = 22
    static let cornerMedium: CGFloat = 14
    static let cornerSmall: CGFloat = 10

    // MARK: - Materials
    static let controlBackground = Material.ultraThin

    // MARK: - Gradients
    /// The app's standard dark backdrop (a hair of lift at the top → black).
    static var appBackgroundGradient: LinearGradient {
        LinearGradient(colors: [Color(white: 0.08), Color.black],
                       startPoint: .top, endPoint: .bottom)
    }
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, Color(red: 0.20, green: 0.70, blue: 0.95)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var warmGradient: LinearGradient {
        LinearGradient(colors: [accentWarm, Color(red: 0.95, green: 0.30, blue: 0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// A floating glass panel used for control clusters and cards. `elevated`
    /// adds a soft drop shadow so the panel reads as lifted off the backdrop.
    func glassPanel(corner: CGFloat = Theme.cornerLarge, elevated: Bool = false) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(elevated ? 0.30 : 0),
                    radius: elevated ? 16 : 0, y: elevated ? 8 : 0)
    }

    /// The app's standard dark gradient background, edge-to-edge.
    func appBackground() -> some View {
        background(Theme.appBackgroundGradient.ignoresSafeArea())
    }
}

/// Press-responsive scale for tappable cards — gives menu/list cards a designed,
/// tactile feel instead of a flat default tap.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Filled accent button for the primary action on a surface.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Glass secondary button for supporting actions.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glassPanel(corner: Theme.cornerMedium)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
