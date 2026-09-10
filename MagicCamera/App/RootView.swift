//
//  RootView.swift
//  Magic Camera
//
//  Home screen. Grouped by INTENT rather than by technology: "scan a space",
//  "capture an object", "your library", "create & edit", "play". Spatial Scan,
//  Object Capture and Room Plan are three engines behind two intents, and
//  presenting them as peer tiles made the user pick a technology before they
//  could state a goal (see docs/analysis/08-coherence-and-ideas.md). Each entry
//  carries a "best for" line so the choice needs no prior knowledge.
//
//  Uses a path-bound NavigationStack so App Intents / Shortcuts / widget deep
//  links can route into a mode via AppRouter.
//

import SwiftUI

struct RootView: View {
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var showARViewer = false
    @State private var deepLinkError: String?
    @State private var showOnboarding = false
    @Bindable private var router = AppRouter.shared
    @Bindable private var settings = AppSettings.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Side-by-side tiles stack into one column once text gets big enough that
    /// two columns would clip or hyphenate.
    private var tileColumns: [GridItem] {
        let count = dynamicTypeSize >= .accessibility1 ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            ScrollView {
                VStack(spacing: 18) {
                    header

                    sectionHeader("Scan a space", "Rooms, areas, interiors")
                    ModeCard(
                        title: "Spatial Scan",
                        subtitle: "Sweep a room into a textured 3D model. Best all-rounder.",
                        systemImage: "cube.transparent",
                        gradient: [Theme.accentWarm, Color(red: 0.95, green: 0.3, blue: 0.45)],
                        action: { router.startSpatialScan(profile: .room) })
                    CompactModeTile(
                        title: "Room Plan",
                        detail: "An exact floor plan — walls, doors, furniture",
                        systemImage: "house.fill",
                        gradient: [Color(red: 0.2, green: 0.65, blue: 0.55), Color(red: 0.1, green: 0.45, blue: 0.7)],
                        route: .roomPlan)

                    sectionHeader("Capture an object", "Two ways, depending on size")
                    LazyVGrid(columns: tileColumns, spacing: 12) {
                        CompactModeTile(
                            title: "Quick 3D",
                            detail: "Fast · LiDAR — hand-size and up",
                            systemImage: "cube.transparent",
                            gradient: [Theme.accentWarm, Color(red: 0.95, green: 0.45, blue: 0.35)],
                            action: { router.startSpatialScan(profile: .object) })
                        CompactModeTile(
                            title: "Object Capture",
                            detail: "Detailed · Photos — small, intricate things",
                            systemImage: "rotate.3d",
                            gradient: [Color(red: 0.55, green: 0.4, blue: 0.95), Color(red: 0.9, green: 0.45, blue: 0.85)],
                            route: .objectCapture)
                    }

                    sectionHeader("Your library", nil)
                    ModeCard(
                        title: "Scan Gallery",
                        subtitle: "Browse, reopen and share every saved scan and room.",
                        systemImage: "square.grid.2x2.fill",
                        gradient: [Color(red: 0.95, green: 0.72, blue: 0.25),
                                   Color(red: 0.9, green: 0.45, blue: 0.2)],
                        action: { showGallery = true })

                    sectionHeader("Create & edit", nil)
                    LazyVGrid(columns: tileColumns, spacing: 12) {
                        CompactModeTile(
                            title: "Model Studio",
                            detail: "Combine, clean up and build models",
                            systemImage: "sparkles",
                            gradient: [Color(red: 0.45, green: 0.35, blue: 0.95), Color(red: 0.25, green: 0.6, blue: 0.95)],
                            route: .modelStudio)
                        CompactModeTile(
                            title: "AR Viewer",
                            detail: "Place a model in your room",
                            systemImage: "arkit",
                            gradient: [Color(red: 0.2, green: 0.7, blue: 0.95),
                                       Color(red: 0.4, green: 0.45, blue: 0.95)],
                            action: { showARViewer = true })
                    }

                    // Live Depth makes no scan and feeds nothing downstream — it's
                    // a camera effect. Kept, but visually demoted so it stops
                    // competing with the capture modes.
                    PlainToolRow(
                        title: "Live Depth",
                        detail: "A real-time depth camera effect",
                        systemImage: "camera.filters",
                        route: .liveDepth)
                }
                // The cards are siblings on one backdrop, so on iOS 26 they
                // share a single Liquid Glass pass and their edges blend.
                .glassGroup(spacing: 18)
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
            // Settings ▸ About can clear the "seen" flag to replay the tour. It is
            // raised on dismiss rather than on the flag change so the full-screen
            // cover never races the settings sheet's own dismissal.
            .sheet(isPresented: $showSettings,
                   onDismiss: { showOnboarding = !settings.hasSeenOnboarding }) {
                SettingsView()
            }
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
            // First run: explain the app and prime the camera permission before
            // ARKit raises the system prompt cold inside a capture mode.
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView {
                    settings.hasSeenOnboarding = true
                    showOnboarding = false
                }
            }
            .alert("Couldn't open that scan",
                   isPresented: Binding(get: { deepLinkError != nil },
                                        set: { if !$0 { deepLinkError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deepLinkError ?? "")
            }
            .task {
                CloudStore.shared.start()
                MemoryPressureMonitor.shared.start()
                RecentScansPublisher.publish()
                showOnboarding = !settings.hasSeenOnboarding
            }
            .onOpenURL { handleDeepLink($0) }
        }
    }

    // MARK: - Deep links

    /// Routes the widget's `magiccamera://` deep links to the right destination.
    /// `scan` carries an optional scan id (`magiccamera://scan/<id>`): with one it
    /// opens that saved scan, without one it starts a new capture.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == WidgetSharing.urlScheme else { return }
        switch url.host {
        case "scan":
            if let id = WidgetSharing.scanID(from: url) {
                openSavedScan(id: id)
            } else {
                router.go(to: .spatialScan)
            }
        case "liveDepth": router.go(to: .liveDepth)
        case "gallery":   showGallery = true
        default:          break
        }
    }

    /// Opens one saved scan by file name. Decoding a textured mesh is slow, so it
    /// runs off the main actor; a missing id (renamed or deleted since the widget
    /// snapshot was published) falls back to the gallery rather than dead-ending.
    private func openSavedScan(id: String) {
        guard let item = ScanLibrary.item(withFileName: id) else {
            showGallery = true
            return
        }
        Task {
            do {
                let pick = try await Task.detached(priority: .userInitiated) {
                    try ScanLibrary.load(item)
                }.value
                router.openInSpatialScan(pick)
            } catch {
                deepLinkError = error.localizedDescription
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                BrandMark()
                VStack(alignment: .leading, spacing: 2) {
                    // The nav bar already says "Magic Camera" — this line states
                    // what the app is for instead of repeating the name.
                    Text("Capture the world in 3D")
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text("LiDAR scanning that never leaves your device.")
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
        .accessibilityElement(children: .combine)
    }

    /// An intent group heading: what you're trying to do, plus an optional
    /// clarifier for groups that offer more than one route to the same goal.
    private func sectionHeader(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.5)
                .foregroundStyle(Theme.textSecondary)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(white: 0.06), Color.black],
            startPoint: .top, endPoint: .bottom)
    }
}

/// The app's icon chip. `@ScaledMetric` so it grows with the user's text size
/// instead of leaving a stamp-sized glyph beside accessibility-size text.
private struct BrandMark: View {
    @ScaledMetric(relativeTo: .title2) private var side: CGFloat = 54

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .fill(Theme.accentGradient)
                .frame(width: side, height: side)
                .shadow(color: Theme.accent.opacity(0.45), radius: 14, y: 7)
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: side * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

/// A full-width card. Takes either a route (pushes) or an action (sheet/profile).
private struct ModeCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let gradient: [Color]
    var route: AppRoute?
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let route {
                NavigationLink(value: route) { label }
            } else {
                Button { action?() } label: { label }
            }
        }
        .buttonStyle(PressableCardStyle())
    }

    private var label: some View {
        ModeCardLabel(title: title, subtitle: subtitle,
                      systemImage: systemImage, gradient: gradient)
    }
}

/// A half-width (or `wide`, full-width) tile for a secondary route: the same
/// visual language as the big cards at a fraction of the shout, plus the "best
/// for" line that makes the choice self-explanatory.
private struct CompactModeTile: View {
    let title: String
    let detail: String
    let systemImage: String
    let gradient: [Color]
    var route: AppRoute?
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let route {
                NavigationLink(value: route) { label }
            } else {
                Button { action?() } label: { label }
            }
        }
        .buttonStyle(PressableCardStyle())
    }

    private var label: some View {
        CompactTileLabel(title: title, detail: detail,
                         systemImage: systemImage, gradient: gradient)
    }
}

private struct CompactTileLabel: View {
    let title: String
    let detail: String
    let systemImage: String
    let gradient: [Color]
    var wide = false
    @ScaledMetric(relativeTo: .subheadline) private var chip: CGFloat = 42

    var body: some View {
        // The inner frame already fills whatever width the container offers, so
        // the same tile works in a grid cell and full-width in a plain stack.
        VStack(alignment: .leading, spacing: 10) {
            IconChip(systemImage: systemImage, gradient: gradient, side: chip)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassPanel(elevated: true)
        .accessibilityElement(children: .combine)
    }
}

/// A gradient-filled rounded chip holding an SF Symbol.
private struct IconChip: View {
    let systemImage: String
    let gradient: [Color]
    let side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: side, height: side)
            Image(systemName: systemImage)
                .font(.system(size: side * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

/// The card face, shared by navigation cards and the sheet buttons.
private struct ModeCardLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let gradient: [Color]
    @ScaledMetric(relativeTo: .headline) private var chip: CGFloat = 60

    var body: some View {
        HStack(spacing: 16) {
            IconChip(systemImage: systemImage, gradient: gradient, side: chip)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(16)
        .glassPanel(elevated: true)
        .accessibilityElement(children: .combine)
    }
}

/// The demoted row for a toy/utility that isn't part of the capture spine.
private struct PlainToolRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let route: AppRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(PressableCardStyle())
        .padding(.top, 4)
    }
}
