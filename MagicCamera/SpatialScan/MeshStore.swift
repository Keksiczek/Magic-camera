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
//          imageLength(UInt32) image bytes    (only if hasTexture == 1)
//  Version 3 stores a MULTI-PAGE atlas — one image per page plus the
//  per-triangle page map — replacing v2's single image block with:
//          pageCount(UInt32)
//          per page: imageLength(UInt32) image bytes
//          pageCount(UInt32) pageOfTri bytes  (triangleCount * UInt8)
//  A single-page mesh is still written as v2, so nothing about an unpaged save
//  changes; v3 appears only once a bake actually spans pages. Version 1 (no
//  texture block) and version 2 files both still load.
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
    /// Newest format this writes. Only a paged atlas is written at v3 — an
    /// unpaged mesh stays v2 byte-for-byte, so the common save is unchanged.
    private static let version: UInt32 = 3
    private static let singlePageVersion: UInt32 = 2
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
        // Only a genuinely paged atlas needs the v3 block; everything else keeps
        // producing exactly the bytes it did before paging existed.
        let paged = (textured?.pageCount ?? 1) > 1
        let header: [UInt32] = [
            magic, paged ? version : singlePageVersion, UInt32(mesh.vertices.count),
            UInt32(mesh.indices.count), hasClass ? 1 : 0
        ]
        header.withUnsafeBufferPointer { data.append($0) }
        // Written component-wise (12 bytes/vertex) so it matches the reader and
        // does not depend on SIMD3<Float>'s padded 16-byte stride. Positions and
        // normals are flattened into one contiguous Float buffer and copied in a
        // single bulk append rather than one `append(contentsOf:)` per float — the
        // latter routed through Data's generic Sequence overload and ran a
        // `swift_dynamicCast` per element (millions on a dense mesh).
        data.reserveCapacity(data.count + mesh.vertices.count * 24
                             + mesh.indices.count * 4 + (hasClass ? mesh.vertices.count : 0))
        var floats = [Float32]()
        floats.reserveCapacity(mesh.vertices.count * 6)
        for v in mesh.vertices { floats.append(v.x); floats.append(v.y); floats.append(v.z) }
        for n in mesh.normals { floats.append(n.x); floats.append(n.y); floats.append(n.z) }
        floats.withUnsafeBufferPointer { data.append($0) }
        mesh.indices.withUnsafeBufferPointer { data.append($0) }
        if hasClass { mesh.classifications.withUnsafeBufferPointer { data.append($0) } }

        if let textured,
           textured.mesh.vertices.count == mesh.vertices.count,
           textured.uvs.count == mesh.vertices.count {
            appendU32(1, to: &data)
            appendU32(UInt32(textured.textureSize), to: &data)
            appendU32(UInt32(textured.uvs.count), to: &data)
            for uv in textured.uvs {
                appendFloat(uv.x, to: &data); appendFloat(uv.y, to: &data)
            }
            if paged {
                appendU32(UInt32(textured.pageCount), to: &data)
                for page in textured.textures {
                    appendU32(UInt32(page.count), to: &data)
                    data.append(page)
                }
                appendU32(UInt32(textured.pageOfTri.count), to: &data)
                textured.pageOfTri.withUnsafeBufferPointer { data.append($0) }
            } else {
                appendU32(UInt32(textured.texturePNG.count), to: &data)
                data.append(textured.texturePNG)
            }
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
        guard m == magic, v >= 1, v <= version else { throw StoreError.corrupt }

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

        // Version-2/3 texture block. Offsets past the classification bytes may be
        // unaligned, so everything here reads via loadUnaligned.
        var textured: TexturedMesh?
        if v >= 2, data.count >= expected + 4 {
            textured = data.withUnsafeBytes { raw -> TexturedMesh? in
                var offset = expected
                func readU32() -> UInt32? {
                    guard offset + 4 <= data.count else { return nil }
                    defer { offset += 4 }
                    return raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                }
                guard readU32() == 1, data.count >= offset + 8 else { return nil }
                guard let sizeField = readU32(), let uvField = readU32() else { return nil }
                let textureSize = Int(sizeField)
                let uvCount = Int(uvField)
                guard uvCount == Int(vCount),
                      data.count >= offset + uvCount * 8 + 4 else { return nil }
                var uvs = [SIMD2<Float>](repeating: .zero, count: uvCount)
                for i in 0..<uvCount {
                    uvs[i] = SIMD2<Float>(
                        Float(bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)),
                        Float(bitPattern: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                    offset += 8
                }

                // v2: one image. v3: a page count, that many images, then the
                // per-triangle page map.
                guard let first = readU32() else { return nil }
                if v < 3 {
                    let length = Int(first)
                    guard length > 0, data.count >= offset + length else { return nil }
                    return TexturedMesh(mesh: mesh, uvs: uvs,
                                        texturePNG: data.subdata(in: offset..<(offset + length)),
                                        textureSize: textureSize)
                }
                let pageCount = Int(first)
                guard pageCount > 0, pageCount <= 64 else { return nil }
                var pages: [Data] = []
                pages.reserveCapacity(pageCount)
                for _ in 0..<pageCount {
                    guard let lengthField = readU32() else { return nil }
                    let length = Int(lengthField)
                    guard length > 0, data.count >= offset + length else { return nil }
                    pages.append(data.subdata(in: offset..<(offset + length)))
                    offset += length
                }
                guard let mapField = readU32() else { return nil }
                let mapCount = Int(mapField)
                guard mapCount == Int(iCount) / 3, data.count >= offset + mapCount else { return nil }
                let pageOfTri = [UInt8](data.subdata(in: offset..<(offset + mapCount)))
                return TexturedMesh(mesh: mesh, uvs: uvs, textures: pages,
                                    textureSize: textureSize, pageOfTri: pageOfTri)
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

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { raw in
            data.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: raw.count)
        }
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { raw in
            data.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: raw.count)
        }
    }
}
