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

    /// Blocks until every queued save/clear has run.
    ///
    /// Both writers are `queue.async`, so ordering between them is FIFO and safe —
    /// but nothing outside the queue can know whether a snapshot has actually
    /// landed. At suspension that matters: the app is asked to go away while a save
    /// may still be queued, and the snapshot this whole type exists to leave behind
    /// is the thing that would be lost. It also makes the behaviour testable at all
    /// — a test that clears and then writes the file itself was racing its own
    /// setup, which is how it started failing in a full-suite run and passing alone.
    static func flush() {
        queue.sync { }
    }

    // MARK: - Recovery

    /// The snapshot's timestamp, or nil when there is none.
    static func pending() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
