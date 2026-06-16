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
        let count = cloud.count
        // Build the interleaved body (pos.xyz, rgb, confidence) in one contiguous
        // Float buffer, then copy it into Data with a single bulk append. The old
        // path appended each float via `Data.append(contentsOf: UnsafeRawBufferPointer)`,
        // which routes through the generic Sequence overload and ran a
        // `swift_dynamicCast` per float — ~10M casts for a 1.5M-point cloud. That
        // was both a measured stall and the hot frame of a background-thread crash.
        // On Apple's little-endian CPUs the raw Float32 bytes already match the
        // on-disk layout the decoder reads, so this is byte-for-byte compatible.
        var body = [Float32]()
        body.reserveCapacity(count * 7)
        for i in 0..<count {
            let p = cloud.positions[i], c = cloud.colors[i]
            body.append(p.x); body.append(p.y); body.append(p.z)
            body.append(c.x); body.append(c.y); body.append(c.z)
            body.append(cloud.confidences[i])
        }
        var data = Data(capacity: 12 + count * bytesPerPoint)
        let header: [UInt32] = [magic, version, UInt32(count)]
        header.withUnsafeBufferPointer { data.append($0) }
        body.withUnsafeBufferPointer { data.append($0) }
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

    private static func sanitize(_ name: String) -> String {
        FileStore.sanitize(name, fallback: defaultName())
    }
}
