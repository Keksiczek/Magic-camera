//
//  ReviewToolsReconstruction.swift
//  Magic Camera
//
//  Reconstruction method and detail — the controls that decide what a scan
//  is turned into, and the ones a triangle-density question always leads to.
//
//  Split out of `SpatialScanReviewTools.swift`. The reason those are nominal
//  `struct ... : View` types rather than computed `some View` properties is in
//  that file's header, and it applies to every struct here: a nominal type is a
//  truncation boundary for SwiftUI's mangled type tree, which once grew deep
//  enough to overflow the runtime demangler's stack on entering scan review.
//

import SwiftUI

struct ReconstructionControls: View {
    @Bindable var viewModel: SpatialScanViewModel
    @Binding var showOptions: Bool

    var body: some View {
        VStack(spacing: 12) {
            Button {
                Haptics.impact(.medium); viewModel.makeQuickModel()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isRunning(.makingModel) {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(viewModel.isRunning(.makingModel) ? "Making model…" : "Make 3D model")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .padding(.horizontal, 16)

            Text("Isolates the subject, builds a smooth surface and bakes the texture in one go.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Button {
                Haptics.impact(.medium); viewModel.makeQuickModel(surface: true)
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isRunning(.makingSurface) {
                        ProgressView().controlSize(.small).tint(Theme.textPrimary)
                    } else {
                        Image(systemName: "paintpalette")
                    }
                    Text(viewModel.isRunning(.makingSurface) ? "Building surface…" : "Textured surface")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .padding(.horizontal, 16)

            Text("Open textured surface, kept as-is — no isolating or closing. For rooms, walls, façades, outdoors.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            // Two primary paths above (object model / textured surface) map to the
            // two scan profiles; the method pickers and manual reconstruct live
            // behind one disclosure so the first screen asks ONE question, not five.
            Button {
                Haptics.impact(.light)
                withAnimation(.easeInOut(duration: 0.2)) { showOptions.toggle() }
            } label: {
                HStack {
                    Text("Advanced reconstruction")
                    Spacer()
                    Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showOptions ? "Hide reconstruction options" : "Show reconstruction options")

            if showOptions { reconstructionOptions }

        }
    }

    @ViewBuilder
    private var reconstructionOptions: some View {
        Picker("Method", selection: $viewModel.reconstructMethod) {
            // `.available`, not `.allCases`: photogrammetry needs hardware
            // support and is absent from the simulator SDK, so on a device that
            // can't run it the option is not offered rather than shown failing.
            ForEach(ReconstructionMethod.available) { m in Text(m.rawValue).tag(m) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)

        Text(viewModel.reconstructMethod.hint)
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 20)

        if viewModel.reconstructMethod != .ballPivot {
            Picker("Detail", selection: $viewModel.reconstructDetail) {
                ForEach(MeshDetail.allCases) { d in Text(d.rawValue).tag(d) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
        }

        if let estimate = viewModel.reconstructionEstimateText {
            Text(estimate)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 20)
        }

        Toggle(isOn: $viewModel.adaptiveDensityPrepass) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Adaptive density").font(.subheadline.weight(.semibold))
                Text("Thin flat areas first — more detail per triangle.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 16)

            Button {
                Haptics.impact(.medium); viewModel.reconstructMesh()
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isRunning(.reconstructing) {
                        ProgressView().controlSize(.small).tint(.black)
                    } else {
                        Image(systemName: "square.stack.3d.up.fill")
                    }
                    Text(viewModel.isRunning(.reconstructing) ? "Reconstructing…" : "Reconstruct surface")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Theme.accentWarm, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .padding(.horizontal, 16)

            // One tap straight to a finished model: reconstruct the surface, then
            // run the same scene-aware Smart finish the mesh review offers — the
            // finish action the user wanted here too, not only after reconstructing.
            Button {
                Haptics.impact(.medium); viewModel.reconstructMesh(thenFinish: true)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Smart finish")
                        Text("Reconstruct & complete in one tap")
                            .font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10).padding(.horizontal, 14)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .padding(.horizontal, 16)
    }
}

// MARK: - Cloud tabs

