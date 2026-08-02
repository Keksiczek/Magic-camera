//
//  ReviewToolsMesh.swift
//  Magic Camera
//
//  Mesh review tools — the finish hero button, the grouped edit actions and
//  the view controls.
//
//  Split out of `SpatialScanReviewTools.swift`. The reason those are nominal
//  `struct ... : View` types rather than computed `some View` properties is in
//  that file's header, and it applies to every struct here: a nominal type is a
//  truncation boundary for SwiftUI's mangled type tree, which once grew deep
//  enough to overflow the runtime demangler's stack on entering scan review.
//

import SwiftUI

struct MeshEditTools: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var showMeshMergeGallery: Bool
    @Binding var showPlaceGallery: Bool
    @Binding var showFloorPlan: Bool
    @Binding var cropEnabled: Bool
    @Binding var cropTrim: [Float]
    @State private var showManualTools = false

    var body: some View {
        VStack(spacing: 12) {
            if viewModel.canRemoveStructure {
                Toggle(isOn: $viewModel.removeStructure) {
                    Label("Hide walls & floor", systemImage: "scissors")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.accent)
                .padding(.horizontal, 18)
            }
            // Hero: one scene-aware tap that does the logical finish; the manual
            // grid stays a tap away so the common case reads as one decision.
            smartFinishButton
            ManualToolsToggle(isExpanded: $showManualTools)
            if showManualTools {
                MeshToolGroups(viewModel: viewModel,
                               showMeshMergeGallery: $showMeshMergeGallery,
                               showPlaceGallery: $showPlaceGallery,
                               showFloorPlan: $showFloorPlan)
                CropToolsView(viewModel: viewModel, cropEnabled: $cropEnabled, cropTrim: $cropTrim)
                MirrorControlsView(viewModel: viewModel)
            }
        }
    }

    /// Scene-aware one-tap finish — lifts an object off its support + closes +
    /// fills, or cleans an open surface (flatten walls, denoise, adaptive density),
    /// then smooths. The obvious primary action; the tools below are manual tweaks.
    private var smartFinishButton: some View {
        MeshFinishHeroButton(viewModel: viewModel)
    }

}

/// The primary call-to-action in mesh review: a full-width accent-gradient card
/// that stands out from the subtle tool tiles beneath it, so the one obvious thing
/// to press reads as exactly that. One tap auto-finishes the scan.
struct MeshFinishHeroButton: View {
    let viewModel: SpatialScanViewModel

    var body: some View {
        let busy = viewModel.isRunning(.makingPrintable)
        Button { Haptics.impact(.medium); viewModel.smartFinish() } label: {
            HStack(spacing: 13) {
                ZStack {
                    if busy { ProgressView().controlSize(.regular).tint(.white) }
                    else { Image(systemName: "sparkles").font(.title3.weight(.bold)) }
                }
                .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(busy ? "Finishing…" : "Smart finish")
                        .font(.headline.weight(.bold))
                    Text("Clean & complete the model in one tap")
                        .font(.caption)
                        // 0.82 alpha on the accent fill measured ≈3.4:1 — under
                        // WCAG AA for small text. 0.95 clears it while still
                        // reading as secondary next to the bold headline.
                        .foregroundStyle(.white.opacity(0.95))
                }
                Spacer(minLength: 0)
                if !busy {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold)).opacity(0.7)
                }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 15).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(Theme.accentGradient,
                        in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.45), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy || viewModel.isAutoFixing)
        .opacity(viewModel.isBusy && !busy ? 0.5 : 1)
        .padding(.horizontal, 16)
    }
}

/// The mesh edit actions, grouped by workflow stage into labeled mini-grids so
/// the dozen tools read as Finish / Texture & export / Assemble / Assist instead
/// of one undifferentiated grid. A nominal struct (its own truncation boundary)
/// keeps the SwiftUI type tree shallow — see this file's header note.
struct MeshToolGroups: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var showMeshMergeGallery: Bool
    @Binding var showPlaceGallery: Bool
    @Binding var showFloorPlan: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Finish: repair and tidy the surface geometry.
            ToolSectionHeader("Finish")
            grid {
                meshToolButton("Fill holes", "bandage", busy: viewModel.isRunning(.fillingHoles)) {
                    viewModel.fillHoles()
                }
                meshToolButton("Close base", "square.bottomhalf.filled", busy: viewModel.isRunning(.closingBase)) {
                    viewModel.closeBase()
                }
                meshToolButton("Remove base", "square.tophalf.filled", busy: viewModel.isRunning(.removingBase)) {
                    viewModel.removeBasePlane()
                }
                meshToolButton("Optimize", "wand.and.stars", busy: viewModel.isRunning(.optimizing)) {
                    viewModel.optimizeMesh()
                }
                meshToolButton("Reduce", "arrow.down.right.and.arrow.up.left", busy: viewModel.isRunning(.decimating)) {
                    viewModel.decimateMesh()
                }
            }

            // Texture & export: colour the mesh, render a clip, read a floor plan.
            ToolSectionHeader("Texture & export")
            grid {
                if viewModel.canBakeTexture {
                    meshToolButton(viewModel.texturedMesh != nil ? "Textured ✓" : "Texture",
                                   "paintpalette", busy: viewModel.isRunning(.bakingTexture)) {
                        viewModel.bakeTexture()
                    }
                }
                meshToolButton("Spin clip", "arrow.triangle.2.circlepath.camera", busy: viewModel.isRunning(.exportingVideo)) {
                    viewModel.exportTurntable()
                }
                if viewModel.meshIsClassified {
                    meshToolButton("Plan", "map", busy: false) { showFloorPlan = true }
                }
            }

            // Assemble: bring other scans into this one.
            ToolSectionHeader("Assemble")
            grid {
                meshToolButton("Merge", "square.stack.3d.down.right", busy: viewModel.isRunning(.merging)) {
                    showMeshMergeGallery = true
                }
                meshToolButton("Place", "plus.square.on.square", busy: viewModel.isRunning(.placing)) {
                    showPlaceGallery = true
                }
            }

            // Assist: AI helpers.
            ToolSectionHeader("Assist")
            grid {
                meshToolButton("Auto-fix", "wand.and.sparkles", busy: viewModel.isAutoFixing) {
                    viewModel.autoFix()
                }
                meshToolButton("Describe", "text.bubble", busy: viewModel.isDescribing) {
                    viewModel.describeScan()
                }
                if viewModel.hasAutoFixBackup {
                    meshToolButton("Undo fix", "arrow.uturn.backward", busy: false) {
                        viewModel.undoAutoFix()
                    }
                }
            }
        }
    }

    /// Adaptive grid wrapper — tools wrap to as many columns as fit (sliver-width
    /// buttons on phones were the reason this isn't one HStack).
    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8, content: content)
            .padding(.horizontal, 16)
    }

    private func meshToolButton(_ title: String, _ icon: String, busy: Bool,
                                action: @escaping () -> Void) -> MeshToolButton {
        MeshToolButton(viewModel: viewModel, title: title, icon: icon, busy: busy, action: action)
    }
}

struct MeshViewTools: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var meshCameraMode: MeshCameraMode
    @Binding var walkSensitivity: Float
    @Binding var rulerEnabled: Bool
    @Binding var clipEnabled: Bool
    @Binding var clipHeight: Float

    var body: some View {
        VStack(spacing: 12) {
            Picker("Shading", selection: $viewModel.meshColorMode) {
                ForEach(MeshColorMode.available(classified: viewModel.meshIsClassified)) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if viewModel.meshColorMode == .classification {
                classificationLegend
            }

            Picker("Camera", selection: $meshCameraMode) {
                ForEach(MeshCameraMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if meshCameraMode == .inside {
                Text("Drag to look around · two-finger drag to move through the scan")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            if meshCameraMode == .walk {
                Text("Joystick moves you · drag the view to look around")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                LabeledSlider(title: "Sensitivity", value: $walkSensitivity,
                              range: 0.3...3.5, format: "%.1f", unit: "×")
                    .padding(.horizontal, 18)
            }

            Toggle(isOn: $rulerEnabled) {
                Label(rulerEnabled ? "Tap two points to measure" : "3D ruler",
                      systemImage: "ruler")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 18)

            Toggle(isOn: clipToggleBinding) {
                Label("Cross-section", systemImage: "scissors.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 18)

            if clipEnabled, let range = meshYRange {
                LabeledSlider(title: "Cut height", value: $clipHeight,
                              range: range, format: "%.2f", unit: " m")
                    .padding(.horizontal, 18)
            }
        }
    }

    /// World-Y extent of the current mesh, for the cross-section slider.
    private var meshYRange: ClosedRange<Float>? {
        guard let box = viewModel.effectiveMesh?.boundingBox() else { return nil }
        return box.max.y > box.min.y ? box.min.y...box.max.y : nil
    }

    /// Enabling the cross-section starts with the cut at the top (nothing hidden).
    private var clipToggleBinding: Binding<Bool> {
        Binding(get: { clipEnabled }, set: { on in
            clipEnabled = on
            if on, let range = meshYRange { clipHeight = range.upperBound }
        })
    }

    private var classificationLegend: some View {
        let classes: [MeshClassification] = [.wall, .floor, .ceiling, .table, .seat, .window, .door]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(classes) { c in
                    HStack(spacing: 5) {
                        Circle().fill(Color(c.uiColor)).frame(width: 9, height: 9)
                        Text(c.label).font(.caption2.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Shared tools

/// Reflect-and-merge across a centre plane — completes a one-sided scan.
