//
//  ReviewToolsGeometry.swift
//  Magic Camera
//
//  Mirror and crop: the two tools with their own inline control panels.
//
//  Split out of `SpatialScanReviewTools.swift`. The reason those are nominal
//  `struct ... : View` types rather than computed `some View` properties is in
//  that file's header, and it applies to every struct here: a nominal type is a
//  truncation boundary for SwiftUI's mangled type tree, which once grew deep
//  enough to overflow the runtime demangler's stack on entering scan review.
//

import SwiftUI

struct MirrorControlsView: View {
    let viewModel: SpatialScanViewModel

    var body: some View {
        VStack(spacing: 6) {
            toolSectionHeader("Mirror / symmetry")
            HStack(spacing: 8) {
                mirrorButton("Left–Right", axis: 0)
                mirrorButton("Up–Down", axis: 1)
                mirrorButton("Front–Back", axis: 2)
            }
            .padding(.horizontal, 16)
            Text("Reflects across the centre and merges. Crop to the symmetry plane first to complete a one-sided scan.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
    }

    private func toolSectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.7)
            Spacer()
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 18)
    }

    private func mirrorButton(_ title: String, axis: Int) -> some View {
        Button { Haptics.impact(.medium); viewModel.mirrorModel(axis: axis) } label: {
            Text(title)
                .font(.caption2.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerSmall))
                .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }
}

/// Crop-box tools: per-face trim sliders, a live size read-out, apply / reset.
struct CropToolsView: View {
    let viewModel: SpatialScanViewModel
    @Binding var cropEnabled: Bool
    @Binding var cropTrim: [Float]

    var body: some View {
        VStack(spacing: 10) {
            Toggle(isOn: $cropEnabled) {
                Label("Crop box", systemImage: "crop")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .tint(Theme.accent)
            .padding(.horizontal, 18)
            if cropEnabled {
                cropFaceSliders
                Text(croppedDimsText)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20)
                HStack(spacing: 10) {
                    Button { cropTrim = [0, 0, 0, 0, 0, 0] } label: {
                        Text("Reset")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    Button { Haptics.impact(.medium); applyCrop() } label: {
                        Text(viewModel.isRunning(.cropping) ? "Cropping…" : "Apply crop")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy || cropTrim.allSatisfy { $0 <= 0 })
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var cropFaceSliders: some View {
        VStack(spacing: 6) {
            cropSlider("Left", 0);   cropSlider("Right", 1)
            cropSlider("Bottom", 2); cropSlider("Top", 3)
            cropSlider("Front", 4);  cropSlider("Back", 5)
        }
    }

    private func cropSlider(_ title: String, _ index: Int) -> some View {
        LabeledSlider(title: title,
                      value: Binding(get: { cropTrim[index] * 100 },
                                     set: { cropTrim[index] = min(max($0 / 100, 0), 0.45) }),
                      range: 0...45, format: "%.0f", unit: "%")
            .padding(.horizontal, 18)
    }

    private func cropWorldBox() -> (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        guard let box = viewModel.effectiveMesh?.boundingBox()
                        ?? viewModel.capturedCloud?.boundingBox() else { return nil }
        let ext = box.max - box.min
        let lo = SIMD3<Float>(box.min.x + ext.x * cropTrim[0],
                              box.min.y + ext.y * cropTrim[2],
                              box.min.z + ext.z * cropTrim[4])
        let hi = SIMD3<Float>(box.max.x - ext.x * cropTrim[1],
                              box.max.y - ext.y * cropTrim[3],
                              box.max.z - ext.z * cropTrim[5])
        return (lo, hi)
    }

    private var croppedDimsText: String {
        guard let b = cropWorldBox(), b.lo.x < b.hi.x, b.lo.y < b.hi.y, b.lo.z < b.hi.z else {
            return "Crop box is empty — reduce the trims"
        }
        return "Keeps " + MeasurementFormat.dimensions(b.hi - b.lo)
    }

    private func applyCrop() {
        guard let b = cropWorldBox() else { return }
        viewModel.cropToBox(min: b.lo, max: b.hi)
        cropEnabled = false
        cropTrim = [0, 0, 0, 0, 0, 0]
    }
}

// MARK: - Tool buttons

/// Full-width secondary action button with a busy spinner.
