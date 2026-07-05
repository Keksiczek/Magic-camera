//
//  StudioAutoSave.swift
//  Magic Camera
//
//  Crash/quit recovery for an in-progress Model Studio stage. Mutations debounce
//  a snapshot to Documents/Studio/autosave.mcstage (the same binary format as a
//  saved project). If the app is killed or the screen left with unsaved work,
//  the next visit finds the snapshot and offers to restore it.
//
//  Thread-safe via a private serial queue; callers can write from any thread.
//

import Foundation

enum StudioAutoSave {
    private static let queue = DispatchQueue(label: "com.keks.MagicCamera.studioAutosave",
                                             qos: .utility)

    /// Lives in the Studio projects directory but is hidden from the project
    /// list by its reserved name (the picker filters it out).
    static let fileName = "autosave.mcstage"
    static var url: URL { StageStore.directory.appendingPathComponent(fileName) }

    // MARK: - Writing

    /// Snapshots the stage asynchronously (atomic). An empty stage clears the
    /// snapshot instead — nothing to recover.
    static func save(_ objects: [StudioObject]) {
        guard !objects.isEmpty else { clear(); return }
        let data = StageStore.encode(objects)
        queue.async {
            do { try data.write(to: url, options: .atomic) }
            catch {
                Diagnostics.shared.log("studio autosave FAILED", error.localizedDescription)
            }
        }
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Recovery

    /// The snapshot's timestamp, or nil when there is none.
    static func pending() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
