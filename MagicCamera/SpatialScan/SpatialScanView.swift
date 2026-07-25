//
//  SpatialScanView.swift
//  Magic Camera
//
//  Mode 2 UI: choose point-cloud or mesh scanning (+ quality), scan with a live
//  overlay, then review the result with camera presets, colour modes, point
//  size, save and export. Saved scans are reachable from the toolbar.
//

import Combine
import SwiftUI

/// Tabs of the review-tools drawer: processing actions vs display options.
enum ReviewToolTab: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case view = "View"
    var id: String { rawValue }
}

struct SpatialScanView: View {
    @State private var viewModel = SpatialScanViewModel()
    @State private var autoOrbit = false
    @State private var pendingPreset: CameraPreset?
    @State private var showExport = false
    @State private var showNewScanConfirm = false
    @State private var showGallery = false
    @State private var showMergeGallery = false
    @State private var showMeshMergeGallery = false
    @State private var showPlaceGallery = false
    @State private var autoTargetRequest = false
    @State private var meshCameraMode: MeshCameraMode = .orbit
    @State private var walkVector: CGSize = .zero
    @State private var walkThumb: CGSize = .zero
    @State private var walkSensitivity: Float = 1.2
    @State private var rulerEnabled = false
    @State private var rulerDistance: Float?
    @State private var showFloorPlan = false
    @State private var clipEnabled = false
    @State private var clipHeight: Float = .greatestFiniteMagnitude
    @State private var showReviewTools = false
    @State private var reviewTab: ReviewToolTab = .edit
    /// Drives the blocking processing overlay. Set on a short delay after an
    /// operation starts so quick edits don't flash a full-screen modal.
    @State private var showProcessingOverlay = false
    /// Expert reconstruction knobs (method/detail/prepass) stay tucked away by
    /// default so the review screen leads with the one-tap actions.
    // Mesh settings (method + detail) are shown by default so they're discoverable
    // — users asked for more control over object-mode/detail without hunting.
    @State private var showReconstructOptions = true
    // Crop box: per-face trim fractions [X−, X+, Y−, Y+, Z−, Z+] of the result's
    // bounding box (0 = keep that whole side, up to 0.45).
    @State private var cropEnabled = false
    @State private var cropTrim: [Float] = [0, 0, 0, 0, 0, 0]
    // Lasso: a one-finger loop over the point cloud keeps/deletes enclosed points.
    @State private var lassoEnabled = false
    @State private var lassoKeepInside = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if viewModel.isSupported {
                content
            } else {
                UnsupportedView(
                    title: "LiDAR required",
                    message: "Spatial Scan builds a 3D point cloud or mesh from LiDAR depth. This device doesn't expose ARKit scene depth.")
            }
        }
        .navigationTitle("Spatial Scan")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, newPhase in
            // Leaving the foreground: stop review-time reconstruction / texture
            // bake so the detached CPU work doesn't run into suspension and trip
            // the "failed to terminate in time" watchdog. Present in every scan
            // phase, so it also covers review (where ScanARView isn't mounted).
            if newPhase == .background { viewModel.handleEnterBackground() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryPressure)) { note in
            // Under memory pressure shed the undo history and, when critical,
            // stop the in-flight reconstruction/bake before the system jetsams us
            // (MemoryPressureMonitor). The review screen holds the big clouds, so
            // this is where the shed matters most.
            if let level = note.userInfo?[MemoryPressureMonitor.levelKey] as? MemoryPressureLevel {
                viewModel.respondToMemoryPressure(level)
            }
        }
        .onAppear {
            // Home-screen gallery handoff: the pick is stashed on the router
            // because this view (and its model) didn't exist to receive it.
            if let pick = AppRouter.shared.consumeGalleryPick() {
                switch pick {
                case .cloud(let cloud, let dirs, let keys): viewModel.loadSaved(cloud, directions: dirs, keyframes: keys)
                case .mesh(let mesh, let texed): viewModel.loadSavedMesh(mesh, textured: texed)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // The processing overlay sits on `content`, below the nav bar —
                // gate the gallery here so a saved scan can't be loaded over a
                // running operation.
                Button { showGallery = true } label: { Image(systemName: "folder") }
                    .disabled(viewModel.isBusy)
            }
        }
        .sheet(isPresented: $showGallery) {
            ScanGalleryView(onSelectCloud: { viewModel.loadSaved($0, directions: $1, keyframes: $2) },
                            onSelectMesh: { viewModel.loadSavedMesh($0, textured: $1) })
        }
        .alert("Recover unsaved scan?", isPresented: Binding(
            get: { viewModel.pendingRecovery != nil },
            set: { if !$0 { viewModel.pendingRecovery = nil } })) {
            Button("Restore") { viewModel.restoreAutosave() }
            Button("Delete", role: .destructive) { viewModel.discardAutosave() }
        } message: {
            Text("A scan from a previous session wasn't saved — it was recovered automatically.")
        }
        .sheet(isPresented: $showMergeGallery) {
            ScanGalleryView(onSelectCloud: { cloud, _, _ in viewModel.mergeSavedCloud(cloud) },
                            onSelectMesh: { _, _ in }, mergeKind: .points)
        }
        .sheet(isPresented: $showMeshMergeGallery) {
            ScanGalleryView(onSelectCloud: { _, _, _ in },
                            onSelectMesh: { mesh, _ in viewModel.mergeSavedMesh(mesh) },
                            mergeKind: .mesh)
        }
        .sheet(isPresented: $showPlaceGallery) {
            ScanGalleryView(onSelectCloud: { _, _, _ in },
                            onSelectMesh: { mesh, _ in viewModel.beginPlacement(mesh) },
                            mergeKind: .mesh)
        }
        .sheet(isPresented: Binding(
            get: { viewModel.sceneReport != nil },
            set: { if !$0 { viewModel.sceneReport = nil } })) {
            if let report = viewModel.sceneReport {
                NavigationStack {
                    ScrollView {
                        Text(report)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                    .background(Theme.background)
                    .navigationTitle("Scan report")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { ShareLink(item: report) }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showFloorPlan) {
            if let mesh = viewModel.effectiveMesh, let plan = FloorPlanBuilder.build(from: mesh) {
                FloorPlanView(plan: plan)
            } else {
                ContentUnavailableView("No walls detected", systemImage: "map",
                                       description: Text("A floor plan needs a classified mesh scan with walls."))
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.exportURL != nil },
            set: { if !$0 { viewModel.exportURL = nil } })) {
            if let url = viewModel.exportURL { ShareSheet(items: [url]) }
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.arQuickLookURL != nil },
            set: { if !$0 { viewModel.arQuickLookURL = nil } })) {
            if let url = viewModel.arQuickLookURL {
                ARQuickLookView(url: url).ignoresSafeArea()
            }
        }
    }

    private var content: some View {
        Group {
            switch viewModel.phase {
            case .idle, .scanning, .finishing: scanningSurface
            case .reviewing:                   reviewSurface
            }
        }
        .overlay { processingOverlay }
        .onChange(of: viewModel.isBusy) { _, busy in
            guard busy else { showProcessingOverlay = false; return }
            // Only reveal the modal if the op is still running after a grace
            // period — sub-second edits never flash it. The delayed task only
            // re-checks `isBusy`, not which op: if a *different* op is running
            // by the time it fires, that's fine — the overlay reads the live
            // `activeOperation`/`operationStartedAt`, so it shows the current one.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                if viewModel.isBusy { showProcessingOverlay = true }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showProcessingOverlay)
    }

    /// Blocking overlay for a running background operation: its name, a live
    /// elapsed-time readout (proof it isn't frozen) and a Cancel button wired to
    /// `cancelHeavyWork()` — every review op is cancellable now.
    @ViewBuilder
    private var processingOverlay: some View {
        if showProcessingOverlay, let op = viewModel.activeOperation {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(Theme.textPrimary)
                    Text(op.label)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    if let started = viewModel.operationStartedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(Self.elapsedText(since: started, now: context.date))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Button {
                        Haptics.impact(.medium)
                        viewModel.cancelHeavyWork()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 28).padding(.vertical, 11)
                            .background(Theme.surface, in: Capsule())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityLabel("Cancel \(op.label)")
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(40)
            }
            .transition(.opacity)
        }
    }

    private static func elapsedText(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Scanning

    private var scanningSurface: some View {
        ZStack {
            ScanARView(viewModel: viewModel, autoTargetRequest: $autoTargetRequest)
                .ignoresSafeArea()

            if viewModel.isScanning && viewModel.hasScanTarget && viewModel.scanKind == .points
                && !viewModel.subjectMaskActive {
                ROIFocusOverlay(clearFraction: roiClearFraction,
                                circle: viewModel.roiScreenCircle)
                    .transition(.opacity)
                    .animation(.linear(duration: 0.1), value: viewModel.roiScreenCircle)
            }

            if showOrbitGuide {
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            OrbitCoverageRing(fraction: viewModel.scanOrbitFraction,
                                              sectors: viewModel.scanOrbitSectors,
                                              heading: viewModel.scanOrbitHeading,
                                              elevationBands: viewModel.scanElevationBands)
                            if viewModel.scanOrbitFraction >= 0.85 {
                                Text("Full orbit ✓")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.green, in: Capsule())
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.top, 56)
                .padding(.trailing, 14)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            VStack {
                // Compact, stable-width badges: the texts are short and digits
                // monospaced so the row never overflows and re-wraps as the
                // live counters tick up (which used to read as flicker).
                HStack(spacing: 8) {
                    // During an object scan the info badges step back — the coach
                    // pill + orbit ring carry the guidance for a clean, Apple-like
                    // capture surface.
                    if !showOrbitGuide {
                        StatusBadge(text: scanStatusText,
                                    systemImage: viewModel.scanKind.systemImage,
                                    tint: Theme.accent)
                    }
                    if viewModel.isScanning && viewModel.scanKind == .points {
                        // Photo coverage is the number that decides texture
                        // quality, so it owns a badge. The old confidence +
                        // area-coverage badges are gone from the bar — the coach
                        // pill below already carries both, and five badges pushed
                        // this row off-screen (clipping, of all things, the
                        // photo percentage).
                        if !showOrbitGuide, viewModel.photoCoverage > 0 {
                            StatusBadge(text: "\(Int((viewModel.photoCoverage * 100).rounded()))% photo",
                                        systemImage: "camera.fill",
                                        tint: photoCoverageColor)
                        }
                        qualityViewToggle
                        if viewModel.isScanning { coverageViewToggle }
                    }
                    Spacer()
                    if viewModel.isScanning { RecordingDot() }
                }
                .padding(.horizontal, 14)
                Spacer()
                // Apple-style coaching pill above the shutter for object scans.
                if showOrbitGuide {
                    ObjectScanCoach(orbitFraction: viewModel.scanOrbitFraction,
                                    confidence: viewModel.scanConfidence,
                                    elevationBands: viewModel.scanElevationBands,
                                    smudged: viewModel.lensSmudged)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if viewModel.isScanning && viewModel.scanKind == .points {
                    // Room / area / surface scan: no orbit target, so coach the
                    // sweep from the live coverage + confidence instead.
                    SurfaceScanCoach(coverage: viewModel.scanCoverage,
                                     confidence: viewModel.scanConfidence,
                                     smudged: viewModel.lensSmudged)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                scanControls
            }
            .padding(.vertical, 10)

            toastOverlay
        }
        .background(Theme.background)
    }

    private var scanControls: some View {
        @Bindable var vm = viewModel
        return VStack(spacing: 12) {
            if viewModel.phase == .idle {
                // The unified capture dial: Draft/Balanced/Max density tiers plus
                // the Room and Object profiles, each with its own point budget
                // shown below. Room finishes as a textured surface on its own;
                // Object feeds the isolate → Make 3-D Model workflow. (The old
                // Point/Mesh split stays gone — every choice here is the same
                // dense-cloud capture, differing in density and workflow.)
                Picker("Quality", selection: $vm.captureQuality) {
                    ForEach(CaptureQuality.allCases) { q in Text(q.rawValue).tag(q) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                Text(viewModel.captureQuality.detailLine)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                if viewModel.scanSubject == .object {
                    objectModeControls
                }
                Text(viewModel.captureEstimateText)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                Text(viewModel.scanSubject == .object
                     ? "Circle the object slowly from every side — top and underneath too."
                     : "Sweep the space slowly. Amber marks show what still needs a photo.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if viewModel.canContinueLastScan {
                    Toggle(isOn: $vm.continueLastScan) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continue last scan").font(.subheadline.weight(.semibold))
                            Text("Add this pass to your most recent saved scan — merged automatically when you finish.")
                                .font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.accent)
                    .padding(.horizontal, 18)
                }
            }

            // The tap-to-target ROI is a subject tool — a Room sweeps everything.
            if viewModel.isScanning && viewModel.scanSubject == .object {
                scanTargetControls
            }

            if viewModel.isFinishing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.black)
                    Text("Finishing scan…").font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent,
                            in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
            } else {
                HStack(spacing: 10) {
                    if viewModel.isScanning {
                        Button {
                            Haptics.impact(.light); viewModel.restartScan()
                        } label: {
                            Label("Start over", systemImage: "arrow.counterclockwise")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.surface,
                                            in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        Haptics.impact(.medium); viewModel.isScanning ? viewModel.stopScan() : viewModel.startScan()
                    } label: {
                        Label(viewModel.isScanning ? "Stop Scan" : "Start Scan",
                              systemImage: viewModel.isScanning ? "stop.circle.fill" : "play.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(viewModel.isScanning ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accent),
                                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                            .foregroundStyle(viewModel.isScanning ? Color.white : Color.black)
                    }
                    .buttonStyle(PressableCardStyle())
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 14)
        .glassPanel(elevated: true)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Extra Object-mode controls (shown only when Object quality is selected):
    /// the Object+ fineness toggle and the capture-range slider.
    private var objectModeControls: some View {
        @Bindable var vm = viewModel
        return VStack(spacing: 8) {
            Toggle(isOn: $vm.objectFine) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Object+ (2 mm voxels)").font(.caption.weight(.semibold))
                    Text("Finest detail for coins & jewellery — more memory.")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
            LabeledSlider(title: "Range", value: $vm.objectRange,
                          range: 1.0...2.5, format: "%.1f", unit: " m")
        }
        .padding(.horizontal, 16)
    }

    private var scanTargetControls: some View {
        VStack(spacing: 8) {
            if viewModel.hasScanTarget {
                HStack {
                    StatusBadge(text: String(format: "Target · %.1f m", viewModel.scanTargetRadius),
                                systemImage: "scope", tint: Theme.accent)
                    Spacer()
                    Button { Haptics.impact(.light); viewModel.clearScanTarget() } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                LabeledSlider(title: "Target radius", value: targetRadiusBinding,
                              range: 0.1...2.0, format: "%.1f", unit: " m")
            } else {
                Text("Tap your subject to scan just it — keeps the surroundings out.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button { Haptics.impact(.light); autoTargetRequest = true } label: {
                    Label("Auto-detect subject", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Theme.surface, in: Capsule())
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
        }
        .padding(.horizontal, 16)
    }

    private var targetRadiusBinding: Binding<Float> {
        Binding(get: { viewModel.scanTargetRadius },
                set: { viewModel.updateScanTargetRadius($0) })
    }

    /// Larger ROI radius → a larger clear focus circle (0.30…0.48 of the screen).
    private var roiClearFraction: CGFloat {
        let t = min(max(viewModel.scanTargetRadius / 2.0, 0), 1)
        return 0.30 + 0.18 * CGFloat(t)
    }

    /// Show the Apple-style orbit-coverage ring while capturing a subject (Object
    /// quality, or any targeted point scan) — that's when "walk all the way
    /// around" is the goal. Room/area scans keep the growth-coverage badge.
    private var showOrbitGuide: Bool {
        viewModel.isScanning && viewModel.scanKind == .points
            && (viewModel.captureQuality == .object || viewModel.hasScanTarget)
    }

    private var scanStatusText: String {
        // Every user scan is a point capture now (Room / Object), so the live count
        // is always points; the badge just reads the running total. Photo coverage
        // gets its own badge — appended here it pushed the row past the screen
        // edge and the number was exactly what got clipped off.
        "\(MeasurementFormat.count(viewModel.pointCount)) pts"
    }

    /// Photo-coverage badge colour: green when the bake will mostly have real
    /// photos, amber while noticeable surface would fall back to cloud colour.
    private var photoCoverageColor: Color {
        switch viewModel.photoCoverage {
        case 0.9...: return .green
        case 0.6...: return Color(red: 1, green: 0.75, blue: 0)
        default:     return Theme.accent
        }
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewSurface: some View {
        ZStack {
            reviewViewer

            VStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        StatusBadge(text: resultCountText, systemImage: resultIcon)
                        if let rd = rulerDistance {
                            StatusBadge(text: MeasurementFormat.distance(rd),
                                        systemImage: "ruler", tint: Theme.accent)
                        }
                        Spacer()
                        if viewModel.canUndo || viewModel.canRedo {
                            historyButtons
                        }
                        Button(role: .destructive) { showNewScanConfirm = true } label: {
                            Label("New", systemImage: "arrow.counterclockwise")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .tint(.red)
                        .disabled(viewModel.isBusy)
                    }
                    HStack(spacing: 8) {
                        if let dims = viewModel.dimensionsText {
                            StatusBadge(text: dims, systemImage: "arrow.up.left.and.arrow.down.right",
                                        tint: Theme.accentWarm)
                        }
                        if let vol = viewModel.volumeText {
                            StatusBadge(text: vol, systemImage: "shippingbox", tint: Theme.accentWarm)
                        }
                    }
                }
                .padding(.horizontal, 14)
                Spacer()
                if viewModel.isPlacing {
                    placementControls
                } else {
                    reviewControls
                }
            }
            .padding(.vertical, 10)

            if viewModel.capturedMesh != nil && meshCameraMode == .walk && !viewModel.isPlacing {
                HStack {
                    walkJoystick.padding(.leading, 18)
                    Spacer()
                }
            }

            toastOverlay
        }
        .background(Theme.background)
        .confirmationDialog("Start a new scan?", isPresented: $showNewScanConfirm, titleVisibility: .visible) {
            Button("Discard & start new", role: .destructive) { viewModel.discard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the current result. Save or export it first if you want to keep it.")
        }
        .confirmationDialog("Export", isPresented: $showExport, titleVisibility: .visible) {
            if viewModel.capturedMesh != nil {
                if viewModel.texturedMesh != nil {
                    ForEach(TexturedMeshExporter.Format.allCases) { format in
                        Button(format.rawValue) { viewModel.exportTextured(format: format) }
                    }
                }
                ForEach(MeshExporter.Format.allCases) { format in
                    Button(format.rawValue) { viewModel.exportMesh(format: format) }
                }
            } else {
                ForEach(PointCloudExporter.Format.allCases) { format in
                    Button(format.rawValue) { viewModel.exportPointCloud(format: format) }
                }
                Button("USDZ (points)") { viewModel.exportPointCloudUSDZ() }
            }
            Button("Web viewer (HTML)") { viewModel.exportWebViewer() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var reviewViewer: some View {
        if viewModel.capturedMesh != nil, let mesh = viewModel.effectiveMesh {
            MeshViewer(mesh: mesh,
                       textured: viewModel.removeStructure ? nil : viewModel.texturedMesh,
                       colorMode: viewModel.meshColorMode,
                       cameraMode: meshCameraMode, rulerEnabled: rulerEnabled,
                       clipEnabled: clipEnabled, clipHeight: clipHeight,
                       autoOrbit: autoOrbit,
                       walkVector: walkVector,
                       walkSensitivity: walkSensitivity,
                       placementMesh: viewModel.placementMesh,
                       placementRotation: viewModel.placementRotation,
                       preset: $pendingPreset, rulerDistance: $rulerDistance,
                       placementPosition: Binding(
                           get: { viewModel.placementPosition },
                           set: { viewModel.placementPosition = $0 }))
                .ignoresSafeArea()
        } else if let cloud = viewModel.capturedCloud {
            MetalPointCloudView(cloud: cloud,
                             colorMode: viewModel.colorMode,
                             pointSize: viewModel.pointSize,
                             autoOrbit: autoOrbit,
                             lassoActive: lassoEnabled,
                             onLassoSelect: { indices in
                                 viewModel.applyLasso(insideIndices: indices,
                                                      keepInside: lassoKeepInside)
                             },
                             preset: $pendingPreset)
                .ignoresSafeArea()
        }
    }

    /// On-screen thumbstick for Walk mode: drag to move, release to stop.
    /// Sits at the screen's left edge so it never collides with the drawer.
    private var walkJoystick: some View {
        let radius: CGFloat = 44
        return ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 110, height: 110)
            Circle()
                .fill(Theme.accent.opacity(0.85))
                .frame(width: 46, height: 46)
                .offset(walkThumb)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    var dx = value.translation.width
                    var dy = value.translation.height
                    let length = max(hypot(dx, dy), 1)
                    if length > radius { dx *= radius / length; dy *= radius / length }
                    walkThumb = CGSize(width: dx, height: dy)
                    // Up on the stick = forward.
                    walkVector = CGSize(width: dx / radius, height: -dy / radius)
                }
                .onEnded { _ in
                    walkThumb = .zero
                    walkVector = .zero
                })
        .accessibilityLabel("Walk joystick")
    }

    /// Compact panel shown instead of the review tools while a scan is being
    /// placed: hint, rotation, and Place/Cancel.
    private var placementControls: some View {
        VStack(spacing: 12) {
            Text(viewModel.placementPosition == nil
                 ? "Tap the room where the scan should stand"
                 : "Tap again to move it · rotate below")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if viewModel.placementPosition != nil {
                LabeledSlider(title: "Rotation",
                              value: Binding(
                                get: { viewModel.placementRotation * 180 / .pi },
                                set: { viewModel.placementRotation = $0 * .pi / 180 }),
                              range: 0...360, format: "%.0f", unit: "°")
                    .padding(.horizontal, 18)
            }

            HStack(spacing: 12) {
                Button(role: .cancel) { viewModel.cancelPlacement() } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)

                Button { Haptics.impact(.medium); viewModel.applyPlacement() } label: {
                    HStack(spacing: 8) {
                        if viewModel.isRunning(.placing) {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "checkmark")
                        }
                        Text("Place")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.placementPosition == nil || viewModel.isBusy)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var reviewControls: some View {
        VStack(spacing: 10) {
            presetRow

            if showReviewTools {
                ScrollView {
                    ReviewToolsDrawer(
                        viewModel: viewModel,
                        reviewTab: $reviewTab,
                        showReconstructOptions: $showReconstructOptions,
                        showMergeGallery: $showMergeGallery,
                        showMeshMergeGallery: $showMeshMergeGallery,
                        showPlaceGallery: $showPlaceGallery,
                        showFloorPlan: $showFloorPlan,
                        cropEnabled: $cropEnabled,
                        cropTrim: $cropTrim,
                        lassoEnabled: $lassoEnabled,
                        lassoKeepInside: $lassoKeepInside,
                        meshCameraMode: $meshCameraMode,
                        walkSensitivity: $walkSensitivity,
                        rulerEnabled: $rulerEnabled,
                        clipEnabled: $clipEnabled,
                        clipHeight: $clipHeight)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                }
                .frame(maxHeight: 300)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            toolsToggle
            actionRow
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Review tools: undo/redo, heatmap

    /// Undo / redo for the review edit history.
    private var historyButtons: some View {
        HStack(spacing: 6) {
            historyButton("arrow.uturn.backward", enabled: viewModel.canUndo) { viewModel.undo() }
            historyButton("arrow.uturn.forward", enabled: viewModel.canRedo) { viewModel.redo() }
        }
    }
    private func historyButton(_ icon: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button { Haptics.impact(.light); action() } label: {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textSecondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || viewModel.isBusy)
    }

    /// Icon-only toggle for the live confidence heatmap overlay.
    private var qualityViewToggle: some View {
        Button {
            Haptics.impact(.light)
            viewModel.scanShowConfidence.toggle()
            viewModel.showScanHint(viewModel.scanShowConfidence
                                   ? "Quality heatmap · green solid, red needs another pass"
                                   : "Live colour view")
        } label: {
            Image(systemName: viewModel.scanShowConfidence ? "circle.hexagongrid.fill" : "circle.hexagongrid")
                .font(.caption.weight(.semibold))
                .padding(8)
                .background(viewModel.scanShowConfidence
                            ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .foregroundStyle(viewModel.scanShowConfidence
                                 ? AnyShapeStyle(Color.black) : AnyShapeStyle(Theme.textPrimary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quality heatmap")
    }

    /// Icon-only toggle for the amber "photograph this" coverage blocks.
    private var coverageViewToggle: some View {
        Button {
            Haptics.impact(.light)
            viewModel.scanShowCoverage.toggle()
            viewModel.showScanHint(viewModel.scanShowCoverage
                                   ? "Amber = no photo yet · sweep it to texture it"
                                   : "Photo coverage hidden")
        } label: {
            Image(systemName: viewModel.scanShowCoverage ? "camera.viewfinder" : "camera")
                .font(.caption.weight(.semibold))
                .padding(8)
                .background(viewModel.scanShowCoverage
                            ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .foregroundStyle(viewModel.scanShowCoverage
                                 ? AnyShapeStyle(Color.black) : AnyShapeStyle(Theme.textPrimary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo coverage")
    }

    /// Chevron handle that opens / closes the edit-tools drawer.
    private var toolsToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { showReviewTools.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                Text(showReviewTools ? "Hide tools" : toolsLabel)
                Spacer()
                Image(systemName: showReviewTools ? "chevron.down" : "chevron.up")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var toolsLabel: String {
        viewModel.capturedMesh != nil ? "Edit & view mesh" : "Edit & view cloud"
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(CameraPreset.allCases) { preset in
                Button { pendingPreset = preset } label: {
                    Label(preset.title, systemImage: preset.systemImage)
                        .font(.caption2.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $autoOrbit) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .toggleStyle(.button)
            .tint(Theme.accent)

            if viewModel.hasResult {
                Button { Haptics.impact(.medium); viewModel.presentARQuickLook() } label: {
                    Image(systemName: "arkit")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View in AR")
            }

            if viewModel.capturedMesh != nil {
                Button { Haptics.impact(.medium); viewModel.sendToStudio() } label: {
                    Image(systemName: "cube.transparent")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send to Studio")
                .disabled(viewModel.isBusy)
            }

            Button { Haptics.impact(.light); viewModel.save() } label: {
                Label("Save", systemImage: "tray.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)

            Button { showExport = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var resultCountText: String {
        if viewModel.capturedMesh != nil {
            return "\(viewModel.effectiveMesh?.triangleCount ?? viewModel.pointCount) tris"
        }
        return "\(viewModel.pointCount) pts"
    }

    private var resultIcon: String {
        viewModel.capturedMesh != nil ? "grid" : "circle.grid.3x3.fill"
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = viewModel.toast {
            VStack {
                ToastView(message: toast).padding(.top, 60)
                Spacer()
            }
            .animation(.spring(duration: 0.3), value: viewModel.toast)
        }
    }
}
