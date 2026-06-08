//
//  MeshStore.swift
//  Magic Camera
//
//  Persists reconstructed meshes to disk in a compact binary format and
//  lists/loads them back. Stored under Documents/Scans/<name>.mcmesh, alongside
//  the point-cloud .mcscan files.
//
//  Layout: magic(UInt32) version(UInt32) vertexCount(UInt32) indexCount(UInt32)
//          hasClassification(UInt32)
//          vertices  : vertexCount * 3 * Float32
//          normals   : vertexCount * 3 * Float32
//          indices   : indexCount  * UInt32
//          classes   : vertexCount * UInt8   (only if hasClassification == 1)
//

import Foundation
import simd

struct SavedMesh: Identifiable {
    let url: URL
    let name: String
    let date: Date
    let triangleCount: Int
    var id: URL { url }
}

enum MeshStore {
    enum StoreError: LocalizedError {
        case corrupt
        var errorDescription: String? { "Mesh file is corrupt or unreadable" }
    }

    private static let magic: UInt32 = 0x4D43_4D53 // "MCMS"
    private static let version: UInt32 = 1
    static let fileExtension = "mcmesh"

    static var directory: URL { ScanStore.directory }

    @discardableResult
    static func save(_ mesh: MeshData, name: String) throws -> URL {
        let hasClass = mesh.hasClassification
        var data = Data()
        let header: [UInt32] = [
            magic, version, UInt32(mesh.vertices.count),
            UInt32(mesh.indices.count), hasClass ? 1 : 0
        ]
        header.withUnsafeBytes { data.append(contentsOf: $0) }
        // Written component-wise (12 bytes/vertex) so it matches the reader and
        // does not depend on SIMD3<Float>'s padded 16-byte stride.
        data.reserveCapacity(data.count + mesh.vertices.count * 24
                             + mesh.indices.count * 4 + (hasClass ? mesh.vertices.count : 0))
        for v in mesh.vertices { appendVec3(v, to: &data) }
        for n in mesh.normals { appendVec3(n, to: &data) }
        for i in mesh.indices { appendU32(i, to: &data) }
        if hasClass { data.append(contentsOf: mesh.classifications) }

        let url = directory.appendingPathComponent("\(sanitize(name)).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func load(_ url: URL) throws -> MeshData {
        let data = try Data(contentsOf: url)
        guard data.count >= 20 else { throw StoreError.corrupt }
        let (m, v, vCount, iCount, hasClass) = data.withUnsafeBytes { raw in
            (raw.load(fromByteOffset: 0,  as: UInt32.self),
             raw.load(fromByteOffset: 4,  as: UInt32.self),
             raw.load(fromByteOffset: 8,  as: UInt32.self),
             raw.load(fromByteOffset: 12, as: UInt32.self),
             raw.load(fromByteOffset: 16, as: UInt32.self))
        }
        guard m == magic, v == version else { throw StoreError.corrupt }

        let vertexBytes = Int(vCount) * 3 * MemoryLayout<Float32>.size
        let indexBytes = Int(iCount) * MemoryLayout<UInt32>.size
        let classBytes = hasClass == 1 ? Int(vCount) : 0
        let expected = 20 + vertexBytes * 2 + indexBytes + classBytes
        guard data.count >= expected else { throw StoreError.corrupt }

        var vertices = [SIMD3<Float>](repeating: .zero, count: Int(vCount))
        var normals = [SIMD3<Float>](repeating: .zero, count: Int(vCount))
        var indices = [UInt32](repeating: 0, count: Int(iCount))
        var classifications = [UInt8]()

        data.withUnsafeBytes { raw in
            var offset = 20
            for i in 0..<Int(vCount) {
                vertices[i] = SIMD3<Float>(
                    raw.load(fromByteOffset: offset, as: Float32.self),
                    raw.load(fromByteOffset: offset + 4, as: Float32.self),
                    raw.load(fromByteOffset: offset + 8, as: Float32.self))
                offset += 12
            }
            for i in 0..<Int(vCount) {
                normals[i] = SIMD3<Float>(
                    raw.load(fromByteOffset: offset, as: Float32.self),
                    raw.load(fromByteOffset: offset + 4, as: Float32.self),
                    raw.load(fromByteOffset: offset + 8, as: Float32.self))
                offset += 12
            }
            for i in 0..<Int(iCount) {
                indices[i] = raw.load(fromByteOffset: offset, as: UInt32.self)
                offset += 4
            }
            if hasClass == 1 {
                classifications = [UInt8](repeating: 0, count: Int(vCount))
                for i in 0..<Int(vCount) {
                    classifications[i] = raw.load(fromByteOffset: offset, as: UInt8.self)
                    offset += 1
                }
            }
        }
        return MeshData(vertices: vertices, normals: normals,
                        indices: indices, classifications: classifications)
    }

    static func list() -> [SavedMesh] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return urls
            .filter { $0.pathExtension == fileExtension }
            .compactMap { url -> SavedMesh? in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
                return SavedMesh(url: url, name: url.deletingPathExtension().lastPathComponent,
                                 date: date, triangleCount: triangleCount(of: url))
            }
            .sorted { $0.date > $1.date }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        Thumbnails.delete(for: url)
    }

    static func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Mesh \(formatter.string(from: Date()))"
    }

    // MARK: - Helpers

    private static func triangleCount(of url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count == 16 else { return 0 }
        let indexCount = head.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        return Int(indexCount) / 3
    }

    private static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? defaultName() : cleaned
    }

    private static func appendVec3(_ v: SIMD3<Float>, to data: inout Data) {
        appendFloat(v.x, to: &data); appendFloat(v.y, to: &data); appendFloat(v.z, to: &data)
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
