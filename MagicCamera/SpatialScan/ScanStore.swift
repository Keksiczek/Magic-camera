//
//  ScanStore.swift
//  Magic Camera
//
//  Persists point clouds to disk in a compact binary format and lists/loads
//  them back. Stored under Documents/Scans/<name>.mcscan.
//
//  Layout v1: magic(UInt32) version(UInt32) count(UInt32)
//             then count * [pos.x,pos.y,pos.z, r,g,b, confidence] (7 x Float32)
//  Layout v2: v1 body, then count * [dir.x,dir.y,dir.z] (3 x Float32) — the
//             recorder's per-point Fusion view rays. A reloaded scan keeps them
//             so "Build Surface" / "Textured surface" rebuilds with fusion-rays
//             instead of the slower, lower-quality estimated-normals fallback.
//             v1 files still load (directions come back nil = pre-v2 behaviour).
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
    private static let version2: UInt32 = 2 // adds a trailing per-point view-ray block
    private static let bytesPerPoint = 7 * MemoryLayout<Float32>.size // 28
    private static let bytesPerDirection = 3 * MemoryLayout<Float32>.size // 12

    static var directory: URL { FileStore.directory("Scans") }

    @discardableResult
    static func save(_ cloud: PointCloud, name: String,
                     directions: [SIMD3<Float>]? = nil) throws -> URL {
        let url = directory.appendingPathComponent("\(sanitize(name)).mcscan")
        try encode(cloud, directions: directions).write(to: url, options: .atomic)
        return url
    }

    /// Serialises a cloud into the .mcscan binary layout (shared with autosave).
    /// When `directions` is supplied and index-aligned to the cloud, a v2 file is
    /// written with the per-point view rays appended; otherwise a plain v1 file.
    static func encode(_ cloud: PointCloud, directions: [SIMD3<Float>]? = nil) -> Data {
        let count = cloud.count
        // Only carry directions when they line up 1:1 with the points (the
        // recorder guarantees this; a mismatch means rays were lost upstream).
        let rays = (count > 0 && directions?.count == count) ? directions : nil
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
        let dirBytes = rays != nil ? count * bytesPerDirection : 0
        var data = Data(capacity: 12 + count * bytesPerPoint + dirBytes)
        let header: [UInt32] = [magic, rays != nil ? version2 : version, UInt32(count)]
        header.withUnsafeBufferPointer { data.append($0) }
        body.withUnsafeBufferPointer { data.append($0) }
        if let rays {
            // Same bulk-append discipline as the point body (one contiguous Float
            // buffer, no per-element dynamic casts), appended after it so v1
            // readers that stop at the point body are unaffected.
            var dirBody = [Float32]()
            dirBody.reserveCapacity(count * 3)
            for d in rays { dirBody.append(d.x); dirBody.append(d.y); dirBody.append(d.z) }
            dirBody.withUnsafeBufferPointer { data.append($0) }
        }
        return data
    }

    static func load(_ url: URL) throws -> PointCloud {
        try decode(try Data(contentsOf: url))
    }

    /// Loads a cloud together with its persisted view rays (nil for v1 files).
    static func loadWithDirections(_ url: URL) throws
        -> (cloud: PointCloud, directions: [SIMD3<Float>]?) {
        try decodeWithDirections(try Data(contentsOf: url))
    }

    /// Parses the .mcscan binary layout (shared with autosave recovery), dropping
    /// any persisted view rays. Callers that need the rays use
    /// `decodeWithDirections`.
    static func decode(_ data: Data) throws -> PointCloud {
        try decodeWithDirections(data).cloud
    }

    /// Parses the .mcscan binary layout, returning the v2 per-point view rays when
    /// present. A v1 file (or a v2 file truncated before the ray block) yields nil
    /// directions, so the caller falls back to estimated normals as before.
    static func decodeWithDirections(_ data: Data) throws
        -> (cloud: PointCloud, directions: [SIMD3<Float>]?) {
        guard data.count >= 12 else { throw StoreError.corrupt }
        let (m, v, count) = data.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
            (raw.load(fromByteOffset: 0, as: UInt32.self),
             raw.load(fromByteOffset: 4, as: UInt32.self),
             raw.load(fromByteOffset: 8, as: UInt32.self))
        }
        guard m == magic, v == version || v == version2 else { throw StoreError.corrupt }
        let n = Int(count)
        let pointEnd = 12 + n * bytesPerPoint
        guard data.count >= pointEnd else { throw StoreError.corrupt }

        var cloud = PointCloud()
        cloud.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            var offset = 12
            for _ in 0..<n {
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

        var directions: [SIMD3<Float>]?
        let dirEnd = pointEnd + n * bytesPerDirection
        if v == version2, n > 0, data.count >= dirEnd {
            var dirs = [SIMD3<Float>]()
            dirs.reserveCapacity(n)
            data.withUnsafeBytes { raw in
                var offset = pointEnd
                for _ in 0..<n {
                    let dx = raw.load(fromByteOffset: offset, as: Float32.self)
                    let dy = raw.load(fromByteOffset: offset + 4, as: Float32.self)
                    let dz = raw.load(fromByteOffset: offset + 8, as: Float32.self)
                    dirs.append(SIMD3<Float>(dx, dy, dz))
                    offset += bytesPerDirection
                }
            }
            directions = dirs
        }
        return (cloud, directions)
    }

    static func list() -> [SavedScan] {
        FileStore.entries(in: directory, ext: "mcscan").map {
            SavedScan(url: $0.url, name: $0.name, date: $0.date, pointCount: pointCount(of: $0.url))
        }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        ScanKeyframeStore.delete(for: url)
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
        ScanKeyframeStore.move(from: url, to: dest)
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
