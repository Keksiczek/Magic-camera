//
//  StorageManagerView.swift
//  Magic Camera
//
//  Settings ▸ Storage: how much disk the scan library holds and which scans are
//  the heavy ones. A saved scan is more than its .mcscan/.mcmesh — texture
//  keyframes ride in a .mckeys sidecar (tens of MB with photos) and each item
//  has a thumbnail — so the size shown here is the whole footprint, and
//  deleting a row removes every piece.
//

import SwiftUI

struct StorageManagerView: View {
    struct Entry: Identifiable {
        let item: LibraryItem
        let bytes: Int64
        var id: URL { item.url }
    }

    @State private var entries: [Entry] = []

    private var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        List {
            Section {
                LabeledContent("Scans", value: "\(entries.count)")
                LabeledContent("Total size", value: Self.format(totalBytes))
            }
            Section {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.item.systemImage)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item.name)
                                .lineLimit(1)
                            Text("\(entry.item.countLabel) · \(entry.item.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.format(entry.bytes))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: delete)
            } header: {
                Text("Largest first")
            } footer: {
                Text("Size includes the scan, its texture photos and thumbnail. Deleting here removes all of them.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            ScanLibrary.delete(entries[index].item)
        }
        entries.remove(atOffsets: offsets)
    }

    private func reload() {
        entries = ScanLibrary.allItems()
            .map { Entry(item: $0, bytes: Self.footprint(of: $0.url)) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// The item's whole on-disk footprint: the model file plus its keyframe
    /// sidecar and thumbnail (each best-effort — absent pieces count zero).
    static func footprint(of modelURL: URL) -> Int64 {
        [modelURL,
         ScanKeyframeStore.sidecarURL(for: modelURL),
         Thumbnails.url(for: modelURL)].reduce(0) { sum, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return sum + (size ?? 0)
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
