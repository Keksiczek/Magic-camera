//
//  ScanMeasurementsView.swift
//  Magic Camera
//
//  The measurements panel: what this scan is, in numbers, with a copy button.
//
//  The button owns its own presentation state rather than taking a binding.
//  The review drawer already threads sixteen of them down three levels, and a
//  seventeenth buys nothing — nobody outside needs to know this sheet is open,
//  and the shallower view tree is the one that keeps compiling (see the
//  SpatialScanView type-metadata note in the project memory).
//

import SwiftUI

/// Opens the measurements sheet for whatever the review currently holds.
struct ScanMeasurementsButton: View {
    let viewModel: SpatialScanViewModel
    @State private var isPresented = false

    var body: some View {
        MeshToolButton(viewModel: viewModel, title: "Measure", icon: "ruler",
                       busy: false) { isPresented = true }
            .sheet(isPresented: $isPresented) {
                ScanMeasurementsSheet(metrics: viewModel.currentMetrics)
            }
    }
}

/// Nominal view, deliberately: the sheet's content is a whole screen of layout
/// and inlining it into the tools tree is what makes that tree unbuildable.
struct ScanMeasurementsSheet: View {
    let metrics: ScanMetrics?
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if let metrics {
                    content(metrics)
                } else {
                    ContentUnavailableView(
                        "Nothing to measure yet",
                        systemImage: "ruler",
                        // One literal, not two joined: SwiftUI keys a Text on the
                        // literal itself, and `"a" + "b"` is an expression, so a
                        // split sentence can never be looked up or translated.
                        description: Text("Capture or open a scan first — measurements come from the scan's own geometry."))
                }
            }
            .navigationTitle("Measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func content(_ metrics: ScanMetrics) -> some View {
        List {
            Section {
                ForEach(metrics.rows, id: \.label) { row in
                    LabeledContent(row.label, value: row.value)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.label), \(row.value)")
                }
            } footer: {
                Text("Measured from the captured geometry, not from its bounding box — an L-shaped room measures the L.")
            }
            Section {
                Button {
                    UIPasteboard.general.string = metrics.summaryText
                    Haptics.impact(.light)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy measurements",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: metrics.summaryText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}
