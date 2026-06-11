//
//  RootView.swift
//  Magic Camera
//
//  Home screen: routes to the two capture modes and the sensor report. Uses a
//  path-bound NavigationStack so App Intents / Shortcuts can deep-link into a
//  mode via AppRouter.
//

import SwiftUI

struct RootView: View {
    @State private var showSettings = false
    @Bindable private var router = AppRouter.shared

    var body: some View {
        NavigationStack(path: $router.path) {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    ModeCard(
                        title: "Live Depth Camera",
                        subtitle: "Heatmap, bokeh, edge outline and fog driven by LiDAR depth.",
                        systemImage: "camera.filters",
                        gradient: [Theme.accent, Color(red: 0.2, green: 0.7, blue: 0.95)],
                        route: .liveDepth)

                    ModeCard(
                        title: "Spatial Scan",
                        subtitle: "Sweep a space to build and export a coloured 3D point cloud.",
                        systemImage: "cube.transparent",
                        gradient: [Theme.accentWarm, Color(red: 0.95, green: 0.3, blue: 0.45)],
                        route: .spatialScan)

                    ModeCard(
                        title: "Object Capture",
                        subtitle: "Photogrammetry: orbit a real object to build a photo-real USDZ.",
                        systemImage: "rotate.3d",
                        gradient: [Color(red: 0.55, green: 0.4, blue: 0.95), Color(red: 0.9, green: 0.45, blue: 0.85)],
                        route: .objectCapture)

                    ModeCard(
                        title: "Room Plan",
                        subtitle: "Scan a room into clean walls, openings and furniture (USDZ).",
                        systemImage: "house.fill",
                        gradient: [Color(red: 0.2, green: 0.65, blue: 0.55), Color(red: 0.1, green: 0.45, blue: 0.7)],
                        route: .roomPlan)

                    ModeCard(
                        title: "Sensors",
                        subtitle: "See which depth and motion sensors this device exposes.",
                        systemImage: "sensor.tag.radiowaves.forward",
                        gradient: [Color(white: 0.5), Color(white: 0.25)],
                        route: .sensors)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle("Magic Camera")
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .liveDepth:     LiveDepthCameraView()
                case .spatialScan:   SpatialScanView()
                case .objectCapture: ObjectCaptureEntry()
                case .roomPlan:      RoomPlanEntry()
                case .sensors:       CapabilitiesView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Experimental LiDAR camera")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            if !DeviceCapabilities.hasLiDAR {
                Label("No LiDAR detected — depth modes are limited on this device.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentWarm)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(white: 0.06), Color.black],
            startPoint: .top, endPoint: .bottom)
    }
}

private struct ModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let gradient: [Color]
    let route: AppRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                        .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 60, height: 60)
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .glassPanel()
        }
        .buttonStyle(.plain)
    }
}
