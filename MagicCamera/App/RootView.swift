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
    @State private var showGallery = false
    @State private var showARViewer = false
    @Bindable private var router = AppRouter.shared

    var body: some View {
        NavigationStack(path: $router.path) {
            ScrollView {
                VStack(spacing: 18) {
                    header

                    // One obvious way in: everything scans through Spatial Scan
                    // (its in-scan profiles cover objects, rooms and areas), so
                    // the home screen leads with it instead of asking the user
                    // to choose between three scanning technologies first.
                    ModeCard(
                        title: "Spatial Scan",
                        subtitle: "Scan anything — objects, rooms, areas — into a textured 3D model.",
                        systemImage: "cube.transparent",
                        gradient: [Theme.accentWarm, Color(red: 0.95, green: 0.3, blue: 0.45)],
                        route: .spatialScan)

                    Button { showGallery = true } label: {
                        ModeCardLabel(
                            title: "Scan Gallery",
                            subtitle: "Browse, reopen and share every saved scan and room.",
                            systemImage: "square.grid.2x2.fill",
                            gradient: [Color(red: 0.95, green: 0.72, blue: 0.25),
                                       Color(red: 0.9, green: 0.45, blue: 0.2)])
                    }
                    .buttonStyle(PressableCardStyle())

                    // Specialised tools keep their power but stop competing with
                    // the primary flow — compact tiles instead of a wall of
                    // equally-loud cards.
                    sectionHeader("More tools")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        CompactModeTile(
                            title: "Live Depth",
                            systemImage: "camera.filters",
                            gradient: [Theme.accent, Color(red: 0.2, green: 0.7, blue: 0.95)],
                            route: .liveDepth)
                        CompactModeTile(
                            title: "Object Capture",
                            systemImage: "rotate.3d",
                            gradient: [Color(red: 0.55, green: 0.4, blue: 0.95), Color(red: 0.9, green: 0.45, blue: 0.85)],
                            route: .objectCapture)
                        CompactModeTile(
                            title: "Room Plan",
                            systemImage: "house.fill",
                            gradient: [Color(red: 0.2, green: 0.65, blue: 0.55), Color(red: 0.1, green: 0.45, blue: 0.7)],
                            route: .roomPlan)
                        CompactModeTile(
                            title: "Model Studio",
                            systemImage: "sparkles",
                            gradient: [Color(red: 0.45, green: 0.35, blue: 0.95), Color(red: 0.25, green: 0.6, blue: 0.95)],
                            route: .modelStudio)
                        Button { showARViewer = true } label: {
                            CompactTileLabel(
                                title: "AR Viewer",
                                systemImage: "arkit",
                                gradient: [Color(red: 0.2, green: 0.7, blue: 0.95),
                                           Color(red: 0.4, green: 0.45, blue: 0.95)])
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle("Magic Camera")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .liveDepth:     LiveDepthCameraView()
                case .spatialScan:   SpatialScanView()
                case .objectCapture: ObjectCaptureEntry()
                case .roomPlan:      RoomPlanEntry()
                case .modelStudio:   ModelStudioView()
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
            .sheet(isPresented: $showGallery) {
                ScanGalleryView(
                    onSelectCloud: { cloud, dirs, keyframes in
                        showGallery = false
                        router.openInSpatialScan(.cloud(cloud, dirs, keyframes))
                    },
                    onSelectMesh: { mesh, textured in
                        showGallery = false
                        router.openInSpatialScan(.mesh(mesh, textured))
                    })
            }
            .sheet(isPresented: $showARViewer) { ARViewerView() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                        .fill(Theme.accentGradient)
                        .frame(width: 54, height: 54)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 14, y: 7)
                    Image(systemName: "cube.transparent.fill")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Magic Camera")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Capture the world in 3D with LiDAR.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !DeviceCapabilities.hasLiDAR {
                Label("No LiDAR detected — depth modes are limited on this device.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
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
            ModeCardLabel(title: title, subtitle: subtitle,
                          systemImage: systemImage, gradient: gradient)
        }
        .buttonStyle(PressableCardStyle())
    }
}

/// A half-width tile for the secondary tools: same visual language as the big
/// cards (gradient icon chip on glass) at a fraction of the shout.
private struct CompactModeTile: View {
    let title: String
    let systemImage: String
    let gradient: [Color]
    let route: AppRoute

    var body: some View {
        NavigationLink(value: route) {
            CompactTileLabel(title: title, systemImage: systemImage, gradient: gradient)
        }
        .buttonStyle(PressableCardStyle())
    }
}

private struct CompactTileLabel: View {
    let title: String
    let systemImage: String
    let gradient: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 42, height: 42)
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassPanel(elevated: true)
    }
}

/// The card face, shared by navigation cards and the gallery button.
private struct ModeCardLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let gradient: [Color]

    var body: some View {
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
        .glassPanel(elevated: true)
    }
}
