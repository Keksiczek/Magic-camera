//
//  Theme.swift
//  Magic Camera
//
//  Centralised design tokens so colours, radii and materials stay consistent
//  and intentional across the app (camera-style dark UI).
//

import SwiftUI

enum Theme {
    static let accent = Color(red: 0.30, green: 0.45, blue: 0.95)
    static let accentWarm = Color(red: 1.0, green: 0.55, blue: 0.30)

    static let background = Color.black
    static let surface = Color.white.opacity(0.08)
    static let surfaceStroke = Color.white.opacity(0.14)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.65)

    static let cornerLarge: CGFloat = 22
    static let cornerMedium: CGFloat = 14
    static let cornerSmall: CGFloat = 10

    static let controlBackground = Material.ultraThin
}

extension View {
    /// A floating glass panel used for control clusters.
    func glassPanel(corner: CGFloat = Theme.cornerLarge) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            )
    }
}
