//
//  ScanGalleryView.swift
//  Magic Camera
//
//  Visual gallery of saved scans — point clouds and meshes — as a thumbnail
//  grid. Tapping one loads it into the viewer; long-press / context menu deletes.
//

import SwiftUI

struct ScanGalleryView: View {
    let onSelectCloud: (PointCloud) -> Void
    let onSelectMesh: (MeshData) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [LibraryItem] = []
    @State private var errorMessage: String?
    @State private var pendingDelete: LibraryItem?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("No saved scans", systemImage: "cube.transparent",
                                           description: Text("Point clouds and meshes you save will appear here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(items) { item in
                                Button { open(item) } label: { card(item) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) { delete(item) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(16)
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
            .onAppear { items = ScanLibrary.allItems() }
        }
    }

    private func card(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                    .fill(Theme.surface)
                if let thumb = item.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                } else {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                VStack {
                    HStack {
                        Spacer()
                        Text(item.kind == .mesh ? "MESH" : "POINTS")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(item.kind == .mesh ? Theme.accentWarm : Theme.accent, in: Capsule())
                            .padding(8)
                    }
                    Spacer()
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(item.countLabel) · \(dateFormatter.string(from: item.date))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.top, 8).padding(.horizontal, 2)
        }
    }

    private func open(_ item: LibraryItem) {
        do {
            switch item.kind {
            case .points: onSelectCloud(try ScanStore.load(item.url))
            case .mesh:   onSelectMesh(try MeshStore.load(item.url))
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ item: LibraryItem) {
        ScanLibrary.delete(item)
        items.removeAll { $0.id == item.id }
    }
}
