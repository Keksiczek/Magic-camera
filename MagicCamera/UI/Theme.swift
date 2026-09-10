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
    // A softer periwinkle-blue: the old saturated royal blue read as harsh on the
    // black UI ("the blue surfaces are aggressive"). This keeps the brand-blue
    // identity but lower-chroma and a touch lighter, so filled accent surfaces
    // feel inviting rather than shouting — and one change lifts the whole app.
    static let accent = Color(red: 0.42, green: 0.52, blue: 0.92)
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
        // Softer second stop — the old near-neon cyan made the gradient loud;
        // this keeps a gentle blue→sky shift in step with the calmer accent.
        LinearGradient(colors: [accent, Color(red: 0.34, green: 0.62, blue: 0.90)],
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
    ///
    /// On iOS 26 this is Apple's native Liquid Glass, which genuinely refracts
    /// and reflects the content behind it and reacts to touch; below that it
    /// stays the hand-rolled `.ultraThinMaterial` + hairline it has always been.
    /// Every panel in the app goes through here, so the whole surface upgrades
    /// (and degrades) as one — no screen has to opt in.
    func glassPanel(corner: CGFloat = Theme.cornerLarge, elevated: Bool = false) -> some View {
        modifier(GlassPanel(corner: corner, elevated: elevated))
    }

    /// Wraps a cluster of sibling `glassPanel`s so their glass merges and morphs
    /// as one on iOS 26 (and so the system renders them in a single pass). A
    /// plain passthrough below iOS 26. `spacing` is the distance at which
    /// neighbouring panels start to blend.
    func glassGroup(spacing: CGFloat = 20) -> some View {
        modifier(GlassGroup(spacing: spacing))
    }

    /// The app's standard dark gradient background, edge-to-edge.
    func appBackground() -> some View {
        background(Theme.appBackgroundGradient.ignoresSafeArea())
    }

    /// Bounds Dynamic Type on a camera surface.
    ///
    /// The capture screens are HUDs floating over a live camera feed: they can't
    /// scroll and they mustn't cover the viewfinder, so text that grows without
    /// limit would swallow the picture it is annotating. Everything up to
    /// `accessibility1` (roughly double the default) scales normally; beyond that
    /// it holds. Settings, the gallery and every list screen stay unclamped and
    /// scale all the way — this applies only where the layout physically can't.
    /// (Apple's own Camera does the same.)
    func cameraSurfaceTypeSize() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// The glass surface itself. Split out as a `ViewModifier` so the availability
/// branch lives in exactly one place.
private struct GlassPanel: ViewModifier {
    let corner: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // Native Liquid Glass draws its own edge highlight, so the hairline
            // overlay is dropped here — keeping it would double the rim.
            content
                .glassEffect(.regular, in: .rect(cornerRadius: corner))
                .shadow(color: .black.opacity(elevated ? 0.30 : 0),
                        radius: elevated ? 16 : 0, y: elevated ? 8 : 0)
        } else {
            content
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(elevated ? 0.30 : 0),
                        radius: elevated ? 16 : 0, y: elevated ? 8 : 0)
        }
    }
}

/// Container for a cluster of sibling panels. Below iOS 26 there is nothing to
/// contain, so it disappears entirely rather than adding a layout level.
private struct GlassGroup: ViewModifier {
    let spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
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
