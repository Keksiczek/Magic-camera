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
//  Version 2 appends an optional baked-texture block (so a textured mesh
//  survives save/reload):
//          hasTexture(UInt32)
//          textureSize(UInt32) uvCount(UInt32)
//          uvs       : uvCount * 2 * Float32
//          pngLength(UInt32) png bytes        (only if hasTexture == 1)
//  Version 1 files (no texture block) still load.
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
    private static let version: UInt32 = 2
    static let fileExtension = "mcmesh"

    static var directory: URL { ScanStore.directory }

    /// A loaded .mcmesh: the geometry plus the baked texture when one was saved.
    struct LoadedMesh {
        let mesh: MeshData
        let textured: TexturedMesh?
    }

    @discardableResult
    static func save(_ mesh: MeshData, textured: TexturedMesh? = nil,
                     name: String) throws -> URL {
        let url = directory.appendingPathComponent("\(sanitize(name)).\(fileExtension)")
        try encode(mesh, textured: textured).write(to: url, options: .atomic)
        return url
    }

    /// Serialises a mesh into the .mcmesh binary layout (shared with autosave).
    /// `textured` is written only when it matches `mesh` (same vertex count).
    static func encode(_ mesh: MeshData, textured: TexturedMesh? = nil) -> Data {
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

        if let textured,
           textured.mesh.vertices.count == mesh.vertices.count,
           textured.uvs.count == mesh.vertices.count {
            appendU32(1, to: &data)
            appendU32(UInt32(textured.textureSize), to: &data)
            appendU32(UInt32(textured.uvs.count), to: &data)
            for uv in textured.uvs {
                appendFloat(uv.x, to: &data); appendFloat(uv.y, to: &data)
            }
            appendU32(UInt32(textured.texturePNG.count), to: &data)
            data.append(textured.texturePNG)
        } else {
            appendU32(0, to: &data)
        }
        return data
    }

    static func load(_ url: URL) throws -> MeshData {
        try decodeFull(try Data(contentsOf: url)).mesh
    }

    /// Loads geometry plus the baked texture block when present.
    static func loadFull(_ url: URL) throws -> LoadedMesh {
        try decodeFull(try Data(contentsOf: url))
    }

    /// Parses the .mcmesh binary layout (shared with autosave recovery).
    static func decode(_ data: Data) throws -> MeshData {
        try decodeFull(data).mesh
    }

    static func decodeFull(_ data: Data) throws -> LoadedMesh {
        guard data.count >= 20 else { throw StoreError.corrupt }
        let (m, v, vCount, iCount, hasClass) = data.withUnsafeBytes { raw in
            (raw.load(fromByteOffset: 0,  as: UInt32.self),
             raw.load(fromByteOffset: 4,  as: UInt32.self),
             raw.load(fromByteOffset: 8,  as: UInt32.self),
             raw.load(fromByteOffset: 12, as: UInt32.self),
             raw.load(fromByteOffset: 16, as: UInt32.self))
        }
        guard m == magic, v == 1 || v == version else { throw StoreError.corrupt }

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
        let mesh = MeshData(vertices: vertices, normals: normals,
                            indices: indices, classifications: classifications)

        // Version-2 texture block. Offsets past the classification bytes may be
        // unaligned, so everything here reads via loadUnaligned.
        var textured: TexturedMesh?
        if v >= 2, data.count >= expected + 4 {
            textured = data.withUnsafeBytes { raw -> TexturedMesh? in
                var offset = expected
                let hasTexture = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                offset += 4
                guard hasTexture == 1, data.count >= offset + 8 else { return nil }
                let textureSize = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                offset += 4
                let uvCount = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                offset += 4
                guard uvCount == Int(vCount),
                      data.count >= offset + uvCount * 8 + 4 else { return nil }
                var uvs = [SIMD2<Float>](repeating: .zero, count: uvCount)
                for i in 0..<uvCount {
                    uvs[i] = SIMD2<Float>(
                        Float(bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)),
                        Float(bitPattern: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                    offset += 8
                }
                let pngLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                offset += 4
                guard pngLength > 0, data.count >= offset + pngLength else { return nil }
                let png = data.subdata(in: offset..<(offset + pngLength))
                return TexturedMesh(mesh: mesh, uvs: uvs,
                                    texturePNG: png, textureSize: textureSize)
            }
        }
        return LoadedMesh(mesh: mesh, textured: textured)
    }

    static func list() -> [SavedMesh] {
        FileStore.entries(in: directory, ext: fileExtension).map {
            SavedMesh(url: $0.url, name: $0.name, date: $0.date, triangleCount: triangleCount(of: $0.url))
        }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        Thumbnails.delete(for: url)
        ScanFavorites.remove(url)
    }

    /// Renames a saved mesh, moving its thumbnail and favourite flag with it.
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = directory.appendingPathComponent("\(sanitize(newName)).\(fileExtension)")
        if dest == url { return url }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else { throw ScanStore.StoreError.nameTaken }
        try fm.moveItem(at: url, to: dest)
        Thumbnails.move(from: url, to: dest)
        ScanFavorites.rename(from: url, to: dest)
        return dest
    }

    static func defaultName() -> String { FileStore.timestampedName(prefix: "Mesh") }

    // MARK: - Helpers

    private static func triangleCount(of url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count == 16 else { return 0 }
        let indexCount = head.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        return Int(indexCount) / 3
    }

    private static func sanitize(_ name: String) -> String {
        FileStore.sanitize(name, fallback: defaultName())
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
