//
//  FileStore.swift
//  Magic Camera
//
//  Shared on-disk file management for the binary stores (ScanStore, MeshStore,
//  StageStore). Each store keeps its own compact binary codec and metadata type;
//  this holds the identical bits they all repeated — the Documents subfolder,
//  name sanitising, timestamped default names, and the directory-listing
//  scaffold — so that logic lives (and is fixed) in one place.
//

import Foundation

enum FileStore {
    /// A library subfolder, created on first access. The base is resolved by
    /// `CloudStore`: the iCloud Drive container when sync is on and available,
    /// otherwise the app's local Documents folder. Every model store (ScanStore,
    /// MeshStore, StageStore) inherits iCloud backup through this one call.
    static func directory(_ subfolder: String) -> URL {
        let base = CloudStore.baseDirectory
        let dir = base.appendingPathComponent(subfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Trims a user-entered name, replaces path separators, and falls back to
    /// `fallback` when nothing usable is left.
    static func sanitize(_ name: String, fallback: @autoclosure () -> String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? fallback() : cleaned
    }

    /// "<prefix> yyyy-MM-dd HHmmss" — the default-name pattern every store uses.
    static func timestampedName(prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "\(prefix) \(formatter.string(from: Date()))"
    }

    /// Files in `directory` carrying `ext`, newest first, as (url, name, date).
    /// Each store layers its own count/metadata onto these entries.
    static func entries(in directory: URL, ext: String) -> [(url: URL, name: String, date: Date)] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return urls
            .filter { $0.pathExtension == ext }
            .map { url in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
                return (url: url, name: url.deletingPathExtension().lastPathComponent, date: date)
            }
            .sorted { $0.date > $1.date }
    }
}
