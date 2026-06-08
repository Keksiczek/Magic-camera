//
//  UnsupportedView.swift
//  Magic Camera
//
//  Shown when a depth feature is requested on a device without LiDAR / world
//  tracking. The app states the limitation plainly instead of faking data.
//

import SwiftUI

struct UnsupportedView: View {
    var title: String = "Depth not available"
    var message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
