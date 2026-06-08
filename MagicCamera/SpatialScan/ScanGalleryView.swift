//
//  ScanGalleryView.swift
//  Magic Camera
//
//  Lists saved scans; tapping one loads it into the viewer. Supports delete.
//

import SwiftUI

struct ScanGalleryView: View {
    let onSelect: (PointCloud) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scans: [SavedScan] = []
    @State private var errorMessage: String?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if scans.isEmpty {
                    ContentUnavailableView("No saved scans", systemImage: "tray",
                                           description: Text("Scans you save will appear here."))
                } else {
                    List {
                        ForEach(scans) { scan in
                            Button { open(scan) } label: { row(scan) }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Saved Scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't open scan", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onAppear { scans = ScanStore.list() }
        }
    }

    private func row(_ scan: SavedScan) -> some View {
        HStack {
            Image(systemName: "cube.transparent")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name).font(.body)
                Text("\(scan.pointCount) pts · \(dateFormatter.string(from: scan.date))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func open(_ scan: SavedScan) {
        do {
            let cloud = try ScanStore.load(scan.url)
            onSelect(cloud)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets { ScanStore.delete(scans[index].url) }
        scans.remove(atOffsets: offsets)
    }
}
