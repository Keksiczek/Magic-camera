//
//  ScanAutoSave.swift
//  Magic Camera
//
//  Crash recovery for in-progress scans. While scanning, the recorder's cloud
//  (or the mesh collector's surface) is periodically snapshotted to
//  Documents/Autosave using the same binary formats as the scan library. If
//  the app is killed mid-scan (watchdog, crash, low memory), the next launch
//  finds the snapshot and offers to restore it into the review screen.
//
//  Cleared whenever a scan reaches a safe state (saved or deliberately
//  discarded). Thread-safe via a private serial queue; callers can write from
//  any thread.
//

import Foundation

enum ScanAutoSave {
    /// What kind of unfinished work an autosave snapshot holds.
    enum Pending {
        case cloud(Date)
        case mesh(Date)
    }

    private static let queue = DispatchQueue(label: "com.keks.MagicCamera.autosave",
                                             qos: .utility)

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Autosave", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var cloudURL: URL { directory.appendingPathComponent("autosave.mcscan") }
    private static var meshURL: URL { directory.appendingPathComponent("autosave.mcmesh") }

    // MARK: - Writing

    /// Snapshots a cloud asynchronously (atomic write; safe to call repeatedly).
    /// Persists the recorder's per-point view rays when supplied so a recovered
    /// scan rebuilds with fusion-rays instead of the slower est-normals fallback.
    static func saveCloud(_ cloud: PointCloud, directions: [SIMD3<Float>]? = nil) {
        guard !cloud.isEmpty else { return }
        let data = ScanStore.encode(cloud, directions: directions)
        queue.async {
            try? data.write(to: cloudURL, options: .atomic)
            try? FileManager.default.removeItem(at: meshURL)
        }
    }

    /// Snapshots a mesh asynchronously (atomic write; safe to call repeatedly).
    static func saveMesh(_ mesh: MeshData) {
        guard !mesh.isEmpty else { return }
        let data = MeshStore.encode(mesh)
        queue.async {
            try? data.write(to: meshURL, options: .atomic)
            try? FileManager.default.removeItem(at: cloudURL)
        }
    }

    /// Removes any pending snapshot (scan saved or deliberately discarded).
    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: cloudURL)
            try? FileManager.default.removeItem(at: meshURL)
        }
    }

    // MARK: - Recovery

    /// The pending snapshot's kind and timestamp, or nil when there is none.
    static func pending() -> Pending? {
        let fm = FileManager.default
        func date(of url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        if let date = date(of: cloudURL) { return .cloud(date) }
        if let date = date(of: meshURL) { return .mesh(date) }
        return nil
    }

    /// Loads the pending cloud snapshot with its view rays (nil when missing or
    /// corrupt; directions nil for legacy v1 snapshots).
    static func restoreCloud() -> (cloud: PointCloud, directions: [SIMD3<Float>]?)? {
        guard let data = try? Data(contentsOf: cloudURL),
              let result = try? ScanStore.decodeWithDirections(data) else { return nil }
        return result
    }

    /// Loads the pending mesh snapshot (nil when missing or corrupt).
    static func restoreMesh() -> MeshData? {
        guard let data = try? Data(contentsOf: meshURL) else { return nil }
        return try? MeshStore.decode(data)
    }
}
