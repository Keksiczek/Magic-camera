//
//  ScanGalleryView.swift
//  Magic Camera
//
//  Visual gallery of saved scans — point clouds and meshes — as a thumbnail
//  grid. Tapping one loads it into the viewer. Each item can be searched by name,
//  starred as a favourite, renamed or deleted from its context menu.
//

import SwiftUI

struct ScanGalleryView: View {
    let onSelectCloud: (PointCloud) -> Void
    let onSelectMesh: (MeshData, TexturedMesh?) -> Void
    /// When set, the gallery is a picker for merging into the current scan:
    /// only items of this kind are listed and the title reflects the action.
    var mergeKind: LibraryItem.Kind? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var items: [LibraryItem] = []
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var errorMessage: String?
    @State private var renamingItem: LibraryItem?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Search- and favourite-filtered items, favourites first then newest.
    private var displayItems: [LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return items
            .filter { item in
                (mergeKind == nil || item.kind == mergeKind)
                    && (!favoritesOnly || item.isFavorite)
                    && (query.isEmpty || item.name.lowercased().contains(query))
            }
            .sorted { a, b in
                if a.isFavorite != b.isFavorite { return a.isFavorite }
                return a.date > b.date
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("No saved scans", systemImage: "cube.transparent",
                                           description: Text("Point clouds and meshes you save will appear here."))
                } else if displayItems.isEmpty {
                    ContentUnavailableView.search(text: searchText.isEmpty ? "favourites" : searchText)
                } else {
                    grid
                }
            }
            .navigationTitle(mergeKind != nil ? "Merge a Scan" : "Saved Scans")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search scans")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        Image(systemName: favoritesOnly ? "star.fill" : "star")
                            .foregroundStyle(favoritesOnly ? Theme.accentWarm : Theme.textSecondary)
                    }
                    .accessibilityLabel(favoritesOnly ? "Show all scans" : "Show favourites only")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't complete that", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .alert("Rename scan", isPresented: Binding(
                get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingItem = nil }
                Button("Save") { commitRename() }
            } message: { Text("Choose a new name for this scan.") }
            .onAppear { reload() }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(displayItems) { item in
                    Button { open(item) } label: { card(item) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { toggleFavorite(item) } label: {
                                Label(item.isFavorite ? "Unfavourite" : "Favourite",
                                      systemImage: item.isFavorite ? "star.slash" : "star")
                            }
                            Button { beginRename(item) } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) { delete(item) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(16)
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
                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.accentWarm)
                                .padding(6)
                                .background(.black.opacity(0.35), in: Circle())
                                .padding(8)
                        }
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

    // MARK: - Actions

    private func reload() { items = ScanLibrary.allItems() }

    private func open(_ item: LibraryItem) {
        do {
            switch item.kind {
            case .points: onSelectCloud(try ScanStore.load(item.url))
            case .mesh:
                let loaded = try MeshStore.loadFull(item.url)
                onSelectMesh(loaded.mesh, loaded.textured)
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

    private func toggleFavorite(_ item: LibraryItem) {
        ScanFavorites.toggle(item.url)
        Haptics.impact(.light)
        reload()
    }

    private func beginRename(_ item: LibraryItem) {
        renameText = item.name
        renamingItem = item
    }

    private func commitRename() {
        guard let item = renamingItem else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingItem = nil
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        do {
            try ScanLibrary.rename(item, to: trimmed)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
