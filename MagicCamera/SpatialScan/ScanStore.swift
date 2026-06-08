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
        var errorDescription: String? { "Scan file is corrupt or unreadable" }
    }

    private static let magic: UInt32 = 0x4D43_5043 // "MCPC"
    private static let version: UInt32 = 1
    private static let bytesPerPoint = 7 * MemoryLayout<Float32>.size // 28

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func save(_ cloud: PointCloud, name: String) throws -> URL {
        var data = Data()
        var header: [UInt32] = [magic, version, UInt32(cloud.count)]
        header.withUnsafeBytes { data.append(contentsOf: $0) }
        data.reserveCapacity(data.count + cloud.count * bytesPerPoint)
        for i in 0..<cloud.count {
            appendVec3(cloud.positions[i], to: &data)
            appendVec3(cloud.colors[i], to: &data)
            appendFloat(cloud.confidences[i], to: &data)
        }
        let url = directory.appendingPathComponent("\(sanitize(name)).mcscan")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func load(_ url: URL) throws -> PointCloud {
        let data = try Data(contentsOf: url)
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
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return urls
            .filter { $0.pathExtension == "mcscan" }
            .compactMap { url -> SavedScan? in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
                let count = pointCount(of: url)
                return SavedScan(url: url, name: url.deletingPathExtension().lastPathComponent,
                                 date: date, pointCount: count)
            }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Scan \(formatter.string(from: Date()))"
    }

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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? defaultName() : cleaned
    }
}
