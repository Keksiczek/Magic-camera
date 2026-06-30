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

                    sectionHeader("Live camera")
                    ModeCard(
                        title: "Live Depth Camera",
                        subtitle: "Heatmap, bokeh, edge outline and fog driven by LiDAR depth.",
                        systemImage: "camera.filters",
                        gradient: [Theme.accent, Color(red: 0.2, green: 0.7, blue: 0.95)],
                        route: .liveDepth)

                    sectionHeader("Build a 3D model")
                    Text("Not sure which? Spatial Scan is freeform, Object Capture nails small objects, Room Plan turns rooms into clean walls.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

                    sectionHeader("Create & edit")
                    ModeCard(
                        title: "Model Studio",
                        subtitle: "Create and edit 3D models with prompts or simple shape tools.",
                        systemImage: "sparkles",
                        gradient: [Color(red: 0.45, green: 0.35, blue: 0.95), Color(red: 0.25, green: 0.6, blue: 0.95)],
                        route: .modelStudio)

                    // The gallery is shared by every capture mode, so it lives
                    // on the home screen; picking a scan opens it in Spatial
                    // Scan's viewer. (The sensor report moved into Settings.)
                    sectionHeader("Library")
                    Button { showGallery = true } label: {
                        ModeCardLabel(
                            title: "Scan Gallery",
                            subtitle: "Browse, reopen and share every saved scan and room.",
                            systemImage: "square.grid.2x2.fill",
                            gradient: [Color(red: 0.95, green: 0.72, blue: 0.25),
                                       Color(red: 0.9, green: 0.45, blue: 0.2)])
                    }
                    .buttonStyle(PressableCardStyle())

                    Button { showARViewer = true } label: {
                        ModeCardLabel(
                            title: "AR Viewer",
                            subtitle: "Place any saved scan or room in your space with AR Quick Look.",
                            systemImage: "arkit",
                            gradient: [Color(red: 0.2, green: 0.7, blue: 0.95),
                                       Color(red: 0.4, green: 0.45, blue: 0.95)])
                    }
                    .buttonStyle(PressableCardStyle())
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
                    onSelectCloud: { cloud, dirs in
                        showGallery = false
                        router.openInSpatialScan(.cloud(cloud, dirs))
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
