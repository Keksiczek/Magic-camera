//
//  Thumbnails.swift
//  Magic Camera
//
//  Stores and retrieves a small preview image next to each saved scan/mesh file
//  (Documents/Scans/<file>.png). Best-effort: a missing thumbnail just means the
//  gallery falls back to a placeholder icon.
//

import Foundation
import UIKit

enum Thumbnails {
    /// Thumbnail file living beside a model file (e.g. "Scan X.mcscan.png").
    static func url(for modelURL: URL) -> URL {
        modelURL.appendingPathExtension("png")
    }

    static func write(_ pngData: Data, for modelURL: URL) {
        try? pngData.write(to: url(for: modelURL), options: .atomic)
    }

    static func delete(for modelURL: URL) {
        try? FileManager.default.removeItem(at: url(for: modelURL))
    }

    static func image(for modelURL: URL) -> UIImage? {
        let path = url(for: modelURL)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }
}
