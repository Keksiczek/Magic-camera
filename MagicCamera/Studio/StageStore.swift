//
//  StageStore.swift
//  Magic Camera
//
//  Persists a whole Model Studio stage — every object with its name, colour
//  and geometry — so work-in-progress survives leaving the screen, unlike the
//  gallery export which flattens to one mesh. Stored under Documents/Studio/
//  as <name>.mcstage in a compact binary layout:
//
//  magic(UInt32) version(UInt32) objectCount(UInt32)
//  per object:
//      nameLength(UInt32) name UTF-8 bytes
//      colorNameLength(UInt32) colorName UTF-8 bytes
//      color    : 3 × Float32
//      vertexCount(UInt32) indexCount(UInt32)
//      vertices : vertexCount * 3 * Float32
//      normals  : vertexCount * 3 * Float32
//      indices  : indexCount * UInt32
//  Version 2 appends an optional photo-texture block per object (so an
//  imported, baked scan keeps its texture through a project round-trip):
//      hasTexture(UInt32)
//      textureSize(UInt32) uvCount(UInt32)
//      uvs      : uvCount * 2 * Float32
//      imageLength(UInt32) image bytes    (only if hasTexture == 1)
//  Version 3 stores a MULTI-PAGE atlas — a large room bakes across several
//  sheets — replacing v2's single image block with:
//      pageCount(UInt32)
//      per page: imageLength(UInt32) image bytes
//      mapCount(UInt32) pageOfTri bytes   (triangleCount * UInt8)
//  The version is per FILE, so v3 is written only when some object actually
//  carries pages; a stage of unpaged objects is still written as v2, byte for
//  byte. Version 1 (no texture block) and version 2 files both still load.
//
//  Strings make every later offset unaligned, so reads go via loadUnaligned.
//

import Foundation
import simd

struct SavedStage: Identifiable {
    let url: URL
    let name: String
    let date: Date
    let objectCount: Int
    var id: URL { url }
}

enum StageStore {
    enum StoreError: LocalizedError {
        case corrupt
        case nameTaken
        var errorDescription: String? {
            switch self {
            case .corrupt:   return "Project file is corrupt or unreadable"
            case .nameTaken: return "A project with this name already exists"
            }
        }
    }

    /// One object as stored on disk — the view model rebuilds live
    /// StudioObjects (fresh ids/revisions) from these.
    struct StoredObject {
        let name: String
        let colorName: String
        let color: SIMD3<Float>
        let mesh: MeshData
        let texture: StudioTexture?
    }

    private static let magic: UInt32 = 0x4D43_5347 // "MCSG"
    private static let version: UInt32 = 3
    private static let singlePageVersion: UInt32 = 2
    static let fileExtension = "mcstage"

    static var directory: URL { FileStore.directory("Studio") }

    // MARK: - Save

    @discardableResult
    static func save(_ objects: [StudioObject], name: String) throws -> URL {
        let url = directory.appendingPathComponent("\(sanitize(name)).\(fileExtension)")
        try encode(objects).write(to: url, options: .atomic)
        return url
    }

    static func encode(_ objects: [StudioObject]) -> Data {
        let stored = objects.filter { !$0.mesh.isEmpty }
        // v3 only once something on the stage actually spans pages, so an
        // ordinary project keeps producing exactly the file it did before.
        let paged = stored.contains { ($0.texture?.pageCount ?? 1) > 1 }
        var data = Data()
        appendU32(magic, to: &data)
        appendU32(paged ? version : singlePageVersion, to: &data)
        appendU32(UInt32(stored.count), to: &data)
        for object in stored {
            appendString(object.name, to: &data)
            appendString(object.colorName, to: &data)
            appendFloat(object.color.x, to: &data)
            appendFloat(object.color.y, to: &data)
            appendFloat(object.color.z, to: &data)
            let mesh = object.mesh
            appendU32(UInt32(mesh.vertices.count), to: &data)
            appendU32(UInt32(mesh.indices.count), to: &data)
            for v in mesh.vertices { appendVec3(v, to: &data) }
            // A mesh can carry mismatched normals (never in practice, but the
            // format guarantees vertexCount of them) — pad with up.
            if mesh.normals.count == mesh.vertices.count {
                for n in mesh.normals { appendVec3(n, to: &data) }
            } else {
                for _ in 0..<mesh.vertices.count {
                    appendVec3(SIMD3<Float>(0, 1, 0), to: &data)
                }
            }
            for i in mesh.indices { appendU32(i, to: &data) }

            // Version-2 photo-texture block — written only when its UVs match
            // the geometry (the invariant StudioTexture/TexturedMesh keep).
            if let texture = object.texture,
               texture.uvs.count == mesh.vertices.count, !texture.texturePNG.isEmpty {
                appendU32(1, to: &data)
                appendU32(UInt32(texture.textureSize), to: &data)
                appendU32(UInt32(texture.uvs.count), to: &data)
                for uv in texture.uvs {
                    appendFloat(uv.x, to: &data); appendFloat(uv.y, to: &data)
                }
                if paged {
                    appendU32(UInt32(texture.pageCount), to: &data)
                    for page in texture.textures {
                        appendU32(UInt32(page.count), to: &data)
                        data.append(page)
                    }
                    appendU32(UInt32(texture.pageOfTri.count), to: &data)
                    texture.pageOfTri.withUnsafeBufferPointer { data.append($0) }
                } else {
                    appendU32(UInt32(texture.texturePNG.count), to: &data)
                    data.append(texture.texturePNG)
                }
            } else {
                appendU32(0, to: &data)
            }
        }
        return data
    }

    // MARK: - Load

    static func load(_ url: URL) throws -> [StoredObject] {
        try decode(try Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> [StoredObject] {
        guard data.count >= 12 else { throw StoreError.corrupt }
        return try data.withUnsafeBytes { raw -> [StoredObject] in
            var offset = 0
            func readU32() throws -> UInt32 {
                guard offset + 4 <= data.count else { throw StoreError.corrupt }
                defer { offset += 4 }
                return raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            func readFloat() throws -> Float {
                Float(bitPattern: try readU32())
            }
            func readString() throws -> String {
                let length = Int(try readU32())
                guard length <= 4096, offset + length <= data.count else { throw StoreError.corrupt }
                defer { offset += length }
                return String(decoding: data.subdata(in: offset..<(offset + length)),
                              as: UTF8.self)
            }
            func readBytes(_ length: Int) throws -> Data {
                guard length >= 0, offset + length <= data.count else { throw StoreError.corrupt }
                defer { offset += length }
                return data.subdata(in: offset..<(offset + length))
            }

            let fileVersion = try { () throws -> UInt32 in
                guard try readU32() == magic else { throw StoreError.corrupt }
                let v = try readU32()
                guard v >= 1, v <= version else { throw StoreError.corrupt }
                return v
            }()
            let objectCount = Int(try readU32())
            guard objectCount <= 4096 else { throw StoreError.corrupt }

            var objects: [StoredObject] = []
            objects.reserveCapacity(objectCount)
            for _ in 0..<objectCount {
                let name = try readString()
                let colorName = try readString()
                let color = SIMD3<Float>(try readFloat(), try readFloat(), try readFloat())
                let vertexCount = Int(try readU32())
                let indexCount = Int(try readU32())
                let payload = vertexCount * 24 + indexCount * 4
                guard vertexCount >= 0, indexCount >= 0,
                      offset + payload <= data.count else { throw StoreError.corrupt }

                var vertices = [SIMD3<Float>](repeating: .zero, count: vertexCount)
                var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
                var indices = [UInt32](repeating: 0, count: indexCount)
                for i in 0..<vertexCount {
                    vertices[i] = SIMD3<Float>(try readFloat(), try readFloat(), try readFloat())
                }
                for i in 0..<vertexCount {
                    normals[i] = SIMD3<Float>(try readFloat(), try readFloat(), try readFloat())
                }
                for i in 0..<indexCount {
                    let index = try readU32()
                    guard Int(index) < vertexCount else { throw StoreError.corrupt }
                    indices[i] = index
                }

                var texture: StudioTexture?
                if fileVersion >= 2 {
                    let hasTexture = try readU32()
                    if hasTexture == 1 {
                        let textureSize = Int(try readU32())
                        let uvCount = Int(try readU32())
                        guard uvCount == vertexCount else { throw StoreError.corrupt }
                        var uvs = [SIMD2<Float>](repeating: .zero, count: uvCount)
                        for i in 0..<uvCount {
                            uvs[i] = SIMD2<Float>(try readFloat(), try readFloat())
                        }
                        if fileVersion < 3 {
                            let length = Int(try readU32())
                            let image = try readBytes(length)
                            if length > 0 {
                                texture = StudioTexture(uvs: uvs, texturePNG: image,
                                                        textureSize: textureSize)
                            }
                        } else {
                            let pageCount = Int(try readU32())
                            guard pageCount > 0, pageCount <= 64 else { throw StoreError.corrupt }
                            var pages: [Data] = []
                            pages.reserveCapacity(pageCount)
                            for _ in 0..<pageCount {
                                let length = Int(try readU32())
                                guard length > 0 else { throw StoreError.corrupt }
                                pages.append(try readBytes(length))
                            }
                            let mapCount = Int(try readU32())
                            guard mapCount == indexCount / 3 else { throw StoreError.corrupt }
                            let pageOfTri = [UInt8](try readBytes(mapCount))
                            texture = StudioTexture(uvs: uvs, textures: pages,
                                                    textureSize: textureSize,
                                                    pageOfTri: pageOfTri)
                        }
                    }
                }

                objects.append(StoredObject(
                    name: name, colorName: colorName, color: color,
                    mesh: MeshData(vertices: vertices, normals: normals, indices: indices),
                    texture: texture))
            }
            return objects
        }
    }

    // MARK: - Listing & management

    static func list() -> [SavedStage] {
        FileStore.entries(in: directory, ext: fileExtension)
            .filter { $0.url.lastPathComponent != StudioAutoSave.fileName }
            .map {
                SavedStage(url: $0.url, name: $0.name, date: $0.date,
                           objectCount: objectCount(of: $0.url))
            }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func defaultName() -> String { FileStore.timestampedName(prefix: "Project") }

    // MARK: - Helpers

    private static func objectCount(of url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12 else { return 0 }
        return head.withUnsafeBytes { raw in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic else { return 0 }
            return Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        }
    }

    private static func sanitize(_ name: String) -> String {
        FileStore.sanitize(name, fallback: defaultName())
    }

    private static func appendString(_ string: String, to data: inout Data) {
        let bytes = Data(string.utf8)
        appendU32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendVec3(_ v: SIMD3<Float>, to data: inout Data) {
        appendFloat(v.x, to: &data); appendFloat(v.y, to: &data); appendFloat(v.z, to: &data)
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        appendU32(value.bitPattern, to: &data)
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
