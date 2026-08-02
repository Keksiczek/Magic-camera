//
//  ReviewToolsCloud.swift
//  Magic Camera
//
//  Point-cloud review tools: the edit actions that change the cloud and the
//  view controls that only change how it is drawn.
//
//  Split out of `SpatialScanReviewTools.swift`. The reason those are nominal
//  `struct ... : View` types rather than computed `some View` properties is in
//  that file's header, and it applies to every struct here: a nominal type is a
//  truncation boundary for SwiftUI's mangled type tree, which once grew deep
//  enough to overflow the runtime demangler's stack on entering scan review.
//

import SwiftUI

struct CloudEditTools: View {
    let viewModel: SpatialScanViewModel
    @Binding var showReconstructOptions: Bool
    @Binding var showMergeGallery: Bool
    @Binding var cropEnabled: Bool
    @Binding var cropTrim: [Float]
    @State private var showManualTools = false

    var body: some View {
        VStack(spacing: 12) {
            // Hero: the one-tap path most users want, plus manual reconstruct.
            ReconstructionControls(viewModel: viewModel, showOptions: $showReconstructOptions)

            ManualToolsToggle(isExpanded: $showManualTools)
            if showManualTools { manualTools }
        }
    }

    /// The full tweak surface — hidden until asked for, unchanged in content.
    @ViewBuilder
    private var manualTools: some View {
            // Clean up: refine the raw cloud (isolate the subject, drop strays /
            // reflections, thin flat areas) before a manual reconstruct.
            ToolSectionHeader("Clean up")
            cloudToolButton("Isolate object (cut floor)", busyTitle: "Isolating…",
                            icon: "person.crop.square.filled.and.at.rectangle",
                            busy: viewModel.isRunning(.isolating)) { viewModel.isolateSubject() }
            cloudToolButton("Clean up (remove strays)", busyTitle: "Cleaning…",
                            icon: "sparkles",
                            busy: viewModel.isRunning(.cleaning)) { viewModel.cleanUpCloud() }
            cloudToolButton("Matte filter (cut reflections)", busyTitle: "Filtering…",
                            icon: "rays",
                            busy: viewModel.isRunning(.filteringReflections)) { viewModel.removeUnreliablePoints() }
            cloudToolButton("Adaptive density (thin flat areas)", busyTitle: "Thinning…",
                            icon: "circle.grid.cross",
                            busy: viewModel.isRunning(.thinning)) { viewModel.adaptiveDownsampleCloud() }

            // Assemble: combine, crop or mirror the cloud.
            ToolSectionHeader("Assemble")
            cloudToolButton("Merge a scan", busyTitle: "Merging…",
                            icon: "square.stack.3d.down.right",
                            busy: viewModel.isRunning(.merging)) { showMergeGallery = true }
            CropToolsView(viewModel: viewModel, cropEnabled: $cropEnabled, cropTrim: $cropTrim)
            MirrorControlsView(viewModel: viewModel)

            // Assist: AI helpers and the PLY-export normals step.
            ToolSectionHeader("Assist")
            cloudToolButton("Auto-fix (plans the steps)", busyTitle: "Auto-fixing…",
                            icon: "wand.and.sparkles",
                            busy: viewModel.isAutoFixing) { viewModel.autoFix() }
            cloudToolButton("Describe scan", busyTitle: "Describing…",
                            icon: "text.bubble",
                            busy: viewModel.isDescribing) { viewModel.describeScan() }
            if viewModel.hasAutoFixBackup {
                cloudToolButton("Undo auto-fix", busyTitle: "…",
                                icon: "arrow.uturn.backward",
                                busy: false) { viewModel.undoAutoFix() }
            }
            normalsButton
    }

    private var normalsButton: some View {
        Button { Haptics.impact(.light); viewModel.estimateCloudNormals() } label: {
            let hasNormals = viewModel.capturedCloudNormals != nil
            HStack(spacing: 8) {
                if viewModel.isRunning(.estimatingNormals) {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                } else {
                    Image(systemName: hasNormals ? "checkmark.circle.fill" : "line.3.crossed.swirl.circle")
                }
                Text(viewModel.isRunning(.estimatingNormals) ? "Estimating normals…"
                     : hasNormals ? "Normals ready (PLY)" : "Estimate normals")
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy || viewModel.capturedCloudNormals != nil)
        .padding(.horizontal, 16)
    }

    private func cloudToolButton(_ title: String, busyTitle: String, icon: String,
                                 busy: Bool, action: @escaping () -> Void) -> CloudToolButton {
        CloudToolButton(viewModel: viewModel, title: title, busyTitle: busyTitle,
                        icon: icon, busy: busy, action: action)
    }
}

struct CloudViewTools: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var lassoEnabled: Bool
    @Binding var lassoKeepInside: Bool

    var body: some View {
        VStack(spacing: 12) {
            Picker("Colour", selection: $viewModel.colorMode) {
                ForEach(PointColorMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            LabeledSlider(title: "Point size", value: pointSizeBinding, range: 2...16, format: "%.0f")
                .padding(.horizontal, 18)

            lassoTools
        }
    }

    private var pointSizeBinding: Binding<Float> {
        Binding(get: { Float(viewModel.pointSize) },
                set: { viewModel.pointSize = CGFloat($0) })
    }

    /// Freeform lasso selection over the point cloud (one finger draws the loop).
    private var lassoTools: some View {
        VStack(spacing: 8) {
            Toggle(isOn: $lassoEnabled) {
                Label("Lasso select", systemImage: "lasso")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 18)
            if lassoEnabled {
                Picker("Lasso", selection: $lassoKeepInside) {
                    Text("Keep inside").tag(true)
                    Text("Delete inside").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                Text("Draw a loop around points with one finger · two fingers still move the camera.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - Mesh tabs

