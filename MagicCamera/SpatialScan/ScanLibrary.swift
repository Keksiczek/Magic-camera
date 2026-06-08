//
//  ScanLibrary.swift
//  Magic Camera
//
//  Unifies saved point clouds (.mcscan) and meshes (.mcmesh) into a single,
//  date-sorted list for the gallery, with preview thumbnails.
//

import Foundation
import UIKit

struct LibraryItem: Identifiable {
    enum Kind { case points, mesh }

    let url: URL
    let name: String
    let date: Date
    let kind: Kind
    let count: Int
    var id: URL { url }

    var thumbnail: UIImage? { Thumbnails.image(for: url) }
    var isFavorite: Bool { ScanFavorites.contains(url) }

    var countLabel: String {
        let formatted = LibraryItem.formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return kind == .mesh ? "\(formatted) tris" : "\(formatted) pts"
    }

    var systemImage: String { kind == .mesh ? "grid" : "circle.grid.3x3.fill" }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()
}

enum ScanLibrary {
    static func allItems() -> [LibraryItem] {
        let clouds = ScanStore.list().map {
            LibraryItem(url: $0.url, name: $0.name, date: $0.date, kind: .points, count: $0.pointCount)
        }
        let meshes = MeshStore.list().map {
            LibraryItem(url: $0.url, name: $0.name, date: $0.date, kind: .mesh, count: $0.triangleCount)
        }
        return (clouds + meshes).sorted { $0.date > $1.date }
    }

    static func delete(_ item: LibraryItem) {
        switch item.kind {
        case .points: ScanStore.delete(item.url)
        case .mesh:   MeshStore.delete(item.url)
        }
    }

    /// Renames a library item, returning its new URL.
    @discardableResult
    static func rename(_ item: LibraryItem, to newName: String) throws -> URL {
        switch item.kind {
        case .points: return try ScanStore.rename(item.url, to: newName)
        case .mesh:   return try MeshStore.rename(item.url, to: newName)
        }
    }
}
