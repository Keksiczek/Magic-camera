//
//  ScanStore.swift
//  Magic Camera
//
//  Persists point clouds to disk in a compact binary format and lists/loads
//  them back. Stored under Documents/Scans/<name>.mcscan.
//
//  Layout: magic(UInt32) version(UInt32) count(UInt32)
//          then count * [pos.x,pos.y,pos.z, r,g,b, confidence] (7 x Float32)
//

import Foundation
import simd

struct SavedScan: Identifiable {
    let url: URL
    let name: String
    let date: Date
    let pointCount: Int
    var id: URL { url }
}

enum ScanStore {
    enum StoreError: LocalizedError {
        case corrupt
        case nameTaken
        var errorDescription: String? {
            switch self {
            case .corrupt:   return "Scan file is corrupt or unreadable"
            case .nameTaken: return "A scan with that name already exists"
            }
        }
    }

    private static let magic: UInt32 = 0x4D43_5043 // "MCPC"
    private static let version: UInt32 = 1
    private static let bytesPerPoint = 7 * MemoryLayout<Float32>.size // 28

    static var directory: URL { FileStore.directory("Scans") }

    @discardableResult
    static func save(_ cloud: PointCloud, name: String) throws -> URL {
        let url = directory.appendingPathComponent("\(sanitize(name)).mcscan")
        try encode(cloud).write(to: url, options: .atomic)
        return url
    }

    /// Serialises a cloud into the .mcscan binary layout (shared with autosave).
    static func encode(_ cloud: PointCloud) -> Data {
        var data = Data()
        let header: [UInt32] = [magic, version, UInt32(cloud.count)]
        header.withUnsafeBytes { data.append(contentsOf: $0) }
        data.reserveCapacity(data.count + cloud.count * bytesPerPoint)
        for i in 0..<cloud.count {
            appendVec3(cloud.positions[i], to: &data)
            appendVec3(cloud.colors[i], to: &data)
            appendFloat(cloud.confidences[i], to: &data)
        }
        return data
    }

    static func load(_ url: URL) throws -> PointCloud {
        try decode(try Data(contentsOf: url))
    }

    /// Parses the .mcscan binary layout (shared with autosave recovery).
    static func decode(_ data: Data) throws -> PointCloud {
        guard data.count >= 12 else { throw StoreError.corrupt }
        let (m, v, count) = data.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
            (raw.load(fromByteOffset: 0, as: UInt32.self),
             raw.load(fromByteOffset: 4, as: UInt32.self),
             raw.load(fromByteOffset: 8, as: UInt32.self))
        }
        guard m == magic, v == version else { throw StoreError.corrupt }
        let expected = 12 + Int(count) * bytesPerPoint
        guard data.count >= expected else { throw StoreError.corrupt }

        var cloud = PointCloud()
        data.withUnsafeBytes { raw in
            var offset = 12
            for _ in 0..<Int(count) {
                let px = raw.load(fromByteOffset: offset, as: Float32.self)
                let py = raw.load(fromByteOffset: offset + 4, as: Float32.self)
                let pz = raw.load(fromByteOffset: offset + 8, as: Float32.self)
                let r = raw.load(fromByteOffset: offset + 12, as: Float32.self)
                let g = raw.load(fromByteOffset: offset + 16, as: Float32.self)
                let b = raw.load(fromByteOffset: offset + 20, as: Float32.self)
                let conf = raw.load(fromByteOffset: offset + 24, as: Float32.self)
                cloud.append(position: SIMD3<Float>(px, py, pz),
                             color: SIMD3<Float>(r, g, b), confidence: conf)
                offset += bytesPerPoint
            }
        }
        return cloud
    }

    static func list() -> [SavedScan] {
        FileStore.entries(in: directory, ext: "mcscan").map {
            SavedScan(url: $0.url, name: $0.name, date: $0.date, pointCount: pointCount(of: $0.url))
        }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        Thumbnails.delete(for: url)
        ScanFavorites.remove(url)
    }

    /// Renames a saved scan, moving its thumbnail and favourite flag with it.
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = directory.appendingPathComponent("\(sanitize(newName)).mcscan")
        if dest == url { return url }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { throw StoreError.nameTaken }
        try fm.moveItem(at: url, to: dest)
        Thumbnails.move(from: url, to: dest)
        ScanFavorites.rename(from: url, to: dest)
        return dest
    }

    static func defaultName() -> String { FileStore.timestampedName(prefix: "Scan") }

    // MARK: - Helpers

    private static func pointCount(of url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12 else { return 0 }
        let count = head.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        return Int(count)
    }

    private static func appendVec3(_ v: SIMD3<Float>, to data: inout Data) {
        appendFloat(v.x, to: &data); appendFloat(v.y, to: &data); appendFloat(v.z, to: &data)
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func sanitize(_ name: String) -> String {
        FileStore.sanitize(name, fallback: defaultName())
    }
}
