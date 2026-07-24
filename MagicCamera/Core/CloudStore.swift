//
//  CloudStore.swift
//  Magic Camera
//
//  iCloud Drive backup & sync for the model library. When the user is signed in
//  to iCloud and sync is enabled, the scan/mesh/Studio stores live inside the
//  app's ubiquity container (<container>/Documents) instead of the app's local
//  Documents folder — so every saved scan is backed up, available on all the
//  user's devices, and visible in the Files app under "Magic Camera". When iCloud
//  is unavailable or sync is off, everything stays local exactly as before.
//
//  The single integration point is FileStore.directory(_:), which asks
//  `CloudStore.baseDirectory` where the "Scans"/"Studio" subfolders should live.
//  That resolution is isolation-free (any thread) and cheap: the blocking
//  ubiquity-container lookup runs once, off the main thread, at launch; the
//  result is cached in `CloudContainer`. Crash-recovery autosave deliberately
//  stays local (it is device-specific and transient).
//

import Foundation
import Observation

extension Notification.Name {
    /// Posted when the cloud library may have changed (a scan arrived from
    /// another device, a download finished, or sync was toggled). The gallery
    /// listens and reloads.
    static let cloudLibraryDidChange = Notification.Name("com.keks.MagicCamera.cloudLibraryDidChange")
}

// MARK: - Isolation-free base-directory resolution

/// Thread-safe cache of the resolved ubiquity `Documents` directory. Set once,
/// off-main, after the (blocking) container lookup; read from any isolation by
/// FileStore. `nil` means iCloud is unavailable (not signed in / no entitlement).
enum CloudContainer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _cloudDocuments: URL?
    nonisolated(unsafe) private static var _resolved = false

    static var cloudDocuments: URL? {
        lock.lock(); defer { lock.unlock() }
        return _cloudDocuments
    }

    /// Whether the launch-time container lookup has completed (regardless of
    /// whether a container was found).
    static var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return _resolved
    }

    static func setResolved(_ url: URL?) {
        lock.lock(); _cloudDocuments = url; _resolved = true; lock.unlock()
    }
}

/// The user's iCloud-sync preference, read/written straight to UserDefaults so it
/// is available from any isolation context (mirrors `GPUSettings`). Defaults to
/// on — backup should "just work" once the user is signed in; it stays inert
/// while no container resolves.
enum CloudSyncPreference {
    private static let key = "settings.iCloudSync"

    static var isEnabled: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: key) == nil ? true : d.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - CloudStore

@MainActor
@Observable
final class CloudStore {
    static let shared = CloudStore()

    /// Whether an iCloud Drive container resolved (user signed in + entitlement).
    private(set) var isAvailable = false
    /// A migration or the initial resolution is in flight.
    private(set) var isSyncing = false

    /// Mirror of the persisted preference for the Settings toggle.
    var isEnabled: Bool { CloudSyncPreference.isEnabled }

    private var metadataQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    // MARK: Launch

    /// Resolves the ubiquity container off the main thread, migrates any local
    /// library into it when sync is on, and begins watching for remote changes.
    /// Safe to call more than once; only the first run does the work.
    func start() {
        guard !CloudContainer.isResolved, !isSyncing else { return }
        Task { await resolve() }
    }

    private func resolve() async {
        isSyncing = true
        let cloudDocs = await Task.detached(priority: .utility) {
            CloudStore.resolveContainerDocuments()
        }.value
        CloudContainer.setResolved(cloudDocs)
        isAvailable = (cloudDocs != nil)

        if let cloudDocs, CloudSyncPreference.isEnabled {
            let moved = await Task.detached(priority: .utility) {
                CloudStore.migrateLocalIntoCloud(cloudDocs: cloudDocs)
            }.value
            if moved > 0 { Diagnostics.shared.log("iCloud", "migrated \(moved) file(s) to iCloud") }
            startMetadataQuery()
            refreshDownloads()
        }
        Diagnostics.shared.log("iCloud", isAvailable ? "container ready (sync \(CloudSyncPreference.isEnabled ? "on" : "off"))"
                                                     : "no container (local only)")
        isSyncing = false
        NotificationCenter.default.post(name: .cloudLibraryDidChange, object: nil)
    }

    // MARK: Toggling

    /// Turns sync on (migrate local → iCloud) or off (bring iCloud → local so the
    /// user keeps every scan on this device). No-op beyond storing the preference
    /// when no container has resolved yet.
    func setEnabled(_ enabled: Bool) {
        CloudSyncPreference.isEnabled = enabled
        guard let cloudDocs = CloudContainer.cloudDocuments else {
            NotificationCenter.default.post(name: .cloudLibraryDidChange, object: nil)
            return
        }
        Task { await applyEnabled(enabled, cloudDocs: cloudDocs) }
    }

    private func applyEnabled(_ enabled: Bool, cloudDocs: URL) async {
        isSyncing = true
        if enabled {
            let moved = await Task.detached(priority: .utility) {
                CloudStore.migrateLocalIntoCloud(cloudDocs: cloudDocs)
            }.value
            Diagnostics.shared.log("iCloud", "sync on — migrated \(moved) file(s)")
            startMetadataQuery()
            refreshDownloads()
        } else {
            stopMetadataQuery()
            let moved = await Task.detached(priority: .utility) {
                CloudStore.moveCloudBackToLocal(cloudDocs: cloudDocs)
            }.value
            Diagnostics.shared.log("iCloud", "sync off — brought \(moved) file(s) local")
        }
        isSyncing = false
        NotificationCenter.default.post(name: .cloudLibraryDidChange, object: nil)
    }

    // MARK: Status (for Settings)

    var statusText: String {
        if !isAvailable { return "Not signed in" }
        if isSyncing { return "Syncing…" }
        return isEnabled ? "On" : "Off"
    }

    var statusDetail: String {
        if !isAvailable {
            return "Sign in to iCloud in the system Settings to back up your scans and open them on your other devices."
        }
        return isEnabled
            ? "Saved scans, meshes and Studio projects live in iCloud Drive — backed up and on all your devices, and in the Files app under “Magic Camera”."
            : "Scans are stored only on this device. Turn on to back them up to iCloud Drive."
    }

    // MARK: On-demand download

    /// Requests download of any not-yet-local library files so they can be
    /// opened. Non-blocking; iCloud keeps only metadata local until asked.
    func refreshDownloads() {
        guard let cloudDocs = CloudContainer.cloudDocuments, CloudSyncPreference.isEnabled else { return }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for sub in CloudStore.modelSubfolders {
                let dir = cloudDocs.appendingPathComponent(sub, isDirectory: true)
                guard let items = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]) else { continue }
                for item in items {
                    let status = try? item.resourceValues(
                        forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                    if status != .current {
                        try? fm.startDownloadingUbiquitousItem(at: item)
                    }
                }
            }
        }
    }

    // MARK: Remote-change watching

    private func startMetadataQuery() {
        guard metadataQuery == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")

        let names: [Notification.Name] = [.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.handleMetadataChange() }
                }
            observers.append(token)
        }
        metadataQuery = query
        query.start()
    }

    private func stopMetadataQuery() {
        metadataQuery?.stop()
        metadataQuery = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func handleMetadataChange() {
        refreshDownloads()
        NotificationCenter.default.post(name: .cloudLibraryDidChange, object: nil)
    }
}

// MARK: - Directory resolution & migration (isolation-free)

extension CloudStore {
    /// Library subfolders that follow the user across devices. Autosave is
    /// intentionally excluded — crash recovery is device-local and transient.
    nonisolated static let modelSubfolders = ["Scans", "Studio"]

    /// The app's local Documents folder (the pre-iCloud location).
    nonisolated static var localDocuments: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Where the "Scans"/"Studio" subfolders should live right now: the iCloud
    /// container's Documents when sync is on and a container has resolved, else
    /// the local Documents folder. Cheap and callable from any thread.
    nonisolated static var baseDirectory: URL {
        if CloudSyncPreference.isEnabled, let cloud = CloudContainer.cloudDocuments {
            return cloud
        }
        return localDocuments
    }

    /// Blocking ubiquity-container lookup — must run off the main thread. Returns
    /// the container's Documents directory (created if needed) or nil when iCloud
    /// is unavailable.
    nonisolated static func resolveContainerDocuments() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    /// Maps a file under `sourceRoot` to the same relative path under `destRoot`.
    /// Pure — the migration's core, unit-tested independently of any I/O.
    nonisolated static func mirroredDestination(for url: URL, sourceRoot: URL, destRoot: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let root = sourceRoot.standardizedFileURL.path
        // Match on a path-component boundary so "/…/Documents" can't be mistaken
        // for a prefix of "/…/DocumentsSomething".
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(rootWithSlash) else { return nil }
        let relative = String(path.dropFirst(rootWithSlash.count))
        guard !relative.isEmpty else { return nil }
        return destRoot.appendingPathComponent(relative)
    }

    /// Moves the local library into the iCloud container. Idempotent: files
    /// already present at the destination are skipped, so it is safe to run every
    /// launch (it also sweeps up anything saved during a brief offline window).
    /// Returns how many files were moved.
    @discardableResult
    nonisolated static func migrateLocalIntoCloud(cloudDocs: URL) -> Int {
        moveLibrary(fromRoot: localDocuments, toRoot: cloudDocs, intoCloud: true)
    }

    /// Brings the iCloud library back onto this device (evicts from iCloud). Used
    /// when the user turns sync off. Returns how many files were moved.
    @discardableResult
    nonisolated static func moveCloudBackToLocal(cloudDocs: URL) -> Int {
        moveLibrary(fromRoot: cloudDocs, toRoot: localDocuments, intoCloud: false)
    }

    nonisolated private static func moveLibrary(fromRoot: URL, toRoot: URL, intoCloud: Bool) -> Int {
        let fm = FileManager.default
        var moved = 0
        for sub in modelSubfolders {
            let sourceDir = fromRoot.appendingPathComponent(sub, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(
                at: sourceDir, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                guard let dest = mirroredDestination(for: item, sourceRoot: fromRoot, destRoot: toRoot),
                      !fm.fileExists(atPath: dest.path) else { continue }
                try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                do {
                    try fm.setUbiquitous(intoCloud, itemAt: item, destinationURL: dest)
                    moved += 1
                } catch {
                    // Best-effort: a single failed file must not abort the sweep.
                }
            }
        }
        return moved
    }
}
