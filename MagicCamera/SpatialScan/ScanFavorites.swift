//
//  ScanFavorites.swift
//  Magic Camera
//
//  Tracks which saved scans/meshes the user has starred. Persisted in
//  UserDefaults keyed by file name, so it survives relaunches and follows files
//  through renames. Thread-safe via UserDefaults.
//

import Foundation

enum ScanFavorites {
    private static let key = "gallery.favorites"

    private static var names: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }

    static func contains(_ url: URL) -> Bool {
        names.contains(url.lastPathComponent)
    }

    @discardableResult
    static func toggle(_ url: URL) -> Bool {
        var set = names
        let key = url.lastPathComponent
        let nowFavorite: Bool
        if set.contains(key) { set.remove(key); nowFavorite = false }
        else { set.insert(key); nowFavorite = true }
        names = set
        return nowFavorite
    }

    static func remove(_ url: URL) {
        var set = names
        set.remove(url.lastPathComponent)
        names = set
    }

    /// Migrates the favourite flag when a file is renamed.
    static func rename(from old: URL, to new: URL) {
        var set = names
        if set.remove(old.lastPathComponent) != nil {
            set.insert(new.lastPathComponent)
            names = set
        }
    }
}
