//
//  ExportPresets.swift
//  Magic Camera
//
//  Turns "pick a file extension" into "say what you want to do with it". The
//  export sheet used to list USDZ / OBJ / STL / GLB / PLY / CSV flat, which asks
//  the user to already know which format their target app eats — and gave no
//  hint that a textured room USDZ is 40 MB while its STL is 3 MB.
//
//  Every option carries an estimated size. The texture half of that estimate is
//  EXACT (atlas pages are already-encoded Data); the geometry half is a linear
//  bytes-per-vertex / bytes-per-triangle model per container, so it is a good
//  order-of-magnitude hint, not a promise — hence "≈".
//

import Foundation

/// What an export option actually runs when tapped.
enum ExportAction: Equatable, Sendable {
    case textured(TexturedMeshExporter.Format)
    case mesh(MeshExporter.Format)
    case cloud(PointCloudExporter.Format)
    case cloudUSDZ
    case webViewer
}

/// One row in the export sheet: an intent, the format that serves it, and a size.
struct ExportOption: Identifiable, Sendable {
    let id: String
    /// The intent ("Share in AR"), not the format.
    let title: String
    /// Why you'd pick this one.
    let detail: String
    let systemImage: String
    /// The technical format, shown as a quiet badge.
    let formatLabel: String
    /// Estimated output size in bytes; nil when it can't be modelled.
    let estimatedBytes: Int?
    let action: ExportAction

    var sizeText: String? {
        guard let estimatedBytes else { return nil }
        return "≈ " + ExportSizeEstimate.format(estimatedBytes)
    }
}

/// A titled group of options.
struct ExportGroup: Identifiable {
    let id: String
    let title: String
    let options: [ExportOption]
}

// MARK: - Size model

/// Pure value math (no ModelIO / SceneKit), so it is unit-testable and cheap
/// enough to run while laying out the sheet.
enum ExportSizeEstimate {
    // Per-container coefficients. Geometry is float32 positions + normals
    // (+ uv when textured) per vertex and a UInt32 index triple per triangle.
    static let positionBytes = 12
    static let normalBytes = 12
    static let uvBytes = 8
    static let indexTripleBytes = 12

    /// USDZ is a zip of a binary usdc; float arrays compress a little.
    static let usdzPacking = 0.9
    /// Binary STL: 50 bytes per facet, exactly, plus an 84-byte header.
    static let stlBytesPerTriangle = 50
    static let stlHeaderBytes = 84

    // ASCII containers, measured as average characters per record.
    static let objVertexChars = 34      // "v -1.234567 2.345678 -0.123456\n"
    static let objNormalChars = 34
    static let objFaceChars = 28        // "f 12345//12345 … \n"
    static let plyASCIIPointChars = 46  // xyz floats + 3 ints
    static let plyBinaryPointBytes = 15 // 3 × float32 + 3 × uchar
    static let plyNormalASCIIChars = 30
    static let plyNormalBinaryBytes = 12
    static let csvPointChars = 40
    static let plyHeaderBytes = 320

    /// Geometry-only bytes for a vertex/triangle count in a binary container.
    static func binaryGeometryBytes(vertices: Int, triangles: Int, hasUVs: Bool) -> Int {
        let perVertex = positionBytes + normalBytes + (hasUVs ? uvBytes : 0)
        return vertices * perVertex + triangles * indexTripleBytes
    }

    /// Estimated size of an untextured mesh export.
    static func bytes(mesh vertices: Int, triangles: Int, format: MeshExporter.Format) -> Int {
        switch format {
        case .stl:
            return stlHeaderBytes + triangles * stlBytesPerTriangle
        case .obj:
            return vertices * (objVertexChars + objNormalChars) + triangles * objFaceChars
        case .glb:
            return binaryGeometryBytes(vertices: vertices, triangles: triangles, hasUVs: false)
        case .usdz:
            // AR Quick Look renders single-sided, so the USDZ writer emits
            // double-sided geometry — twice the triangles (and vertices).
            let doubled = binaryGeometryBytes(vertices: vertices * 2,
                                              triangles: triangles * 2, hasUVs: false)
            return Int(Double(doubled) * usdzPacking)
        }
    }

    /// Estimated size of a textured mesh export. The atlas term is exact: the
    /// pages are already-encoded JPEG/PNG `Data` and both containers embed them
    /// byte-for-byte.
    static func bytes(textured: TexturedMesh, format: TexturedMeshExporter.Format) -> Int {
        let atlas = textured.textures.reduce(0) { $0 + $1.count }
        let vertices = textured.mesh.count
        let triangles = textured.mesh.triangleCount
        let geometry = binaryGeometryBytes(vertices: vertices, triangles: triangles, hasUVs: true)
        switch format {
        case .glb:  return atlas + geometry
        case .usdz: return atlas + Int(Double(geometry) * usdzPacking)
        }
    }

    /// Estimated size of a point-cloud export. `hasNormals` only affects PLY.
    static func bytes(points: Int, format: PointCloudExporter.Format, hasNormals: Bool) -> Int {
        switch format {
        case .plyBinary:
            let perPoint = plyBinaryPointBytes + (hasNormals ? plyNormalBinaryBytes : 0)
            return plyHeaderBytes + points * perPoint
        case .plyASCII:
            let perPoint = plyASCIIPointChars + (hasNormals ? plyNormalASCIIChars : 0)
            return plyHeaderBytes + points * perPoint
        case .obj:
            return points * objVertexChars
        case .csv:
            return points * csvPointChars
        }
    }

    /// Points exported as USDZ point geometry: positions + colours, zipped.
    static func bytesPointUSDZ(points: Int) -> Int {
        Int(Double(points * (positionBytes + 12)) * usdzPacking)
    }

    /// The self-contained web viewer: the model in a JSON/base64 payload inside
    /// one HTML file, so roughly the binary geometry plus the atlas, inflated by
    /// base64's 4/3.
    static func bytesWebViewer(vertices: Int, triangles: Int, atlasBytes: Int) -> Int {
        let payload = binaryGeometryBytes(vertices: vertices, triangles: triangles,
                                          hasUVs: atlasBytes > 0) + atlasBytes
        return Int(Double(payload) * 4.0 / 3.0)
    }

    static func format(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Catalogue

enum ExportCatalogue {
    /// The options available for the current review state, grouped by intent.
    /// `textured` wins over `mesh` where both exist (same geometry, with colour).
    static func groups(textured: TexturedMesh?, mesh: MeshData?,
                       cloudPoints: Int, cloudHasNormals: Bool) -> [ExportGroup] {
        var groups: [ExportGroup] = []
        let atlasBytes = textured?.textures.reduce(0) { $0 + $1.count } ?? 0

        if let mesh, !mesh.isEmpty {
            let vertices = mesh.count
            let triangles = mesh.triangleCount
            var share: [ExportOption] = []

            if let textured {
                share.append(ExportOption(
                    id: "ar-usdz-textured",
                    title: "Share in AR",
                    detail: "Opens straight into AR Quick Look on any iPhone or Mac. With colour.",
                    systemImage: "arkit",
                    formatLabel: "USDZ",
                    estimatedBytes: ExportSizeEstimate.bytes(textured: textured, format: .usdz),
                    action: .textured(.usdz)))
                share.append(ExportOption(
                    id: "universal-glb-textured",
                    title: "Open anywhere",
                    detail: "Blender, Unity, Godot, web viewers. With colour.",
                    systemImage: "shippingbox",
                    formatLabel: "GLB",
                    estimatedBytes: ExportSizeEstimate.bytes(textured: textured, format: .glb),
                    action: .textured(.glb)))
            } else {
                share.append(ExportOption(
                    id: "ar-usdz",
                    title: "Share in AR",
                    detail: "Opens straight into AR Quick Look. Bake a texture first for colour.",
                    systemImage: "arkit",
                    formatLabel: "USDZ",
                    estimatedBytes: ExportSizeEstimate.bytes(mesh: vertices, triangles: triangles, format: .usdz),
                    action: .mesh(.usdz)))
                share.append(ExportOption(
                    id: "universal-glb",
                    title: "Open anywhere",
                    detail: "Blender, Unity, Godot, web viewers.",
                    systemImage: "shippingbox",
                    formatLabel: "GLB",
                    estimatedBytes: ExportSizeEstimate.bytes(mesh: vertices, triangles: triangles, format: .glb),
                    action: .mesh(.glb)))
            }
            share.append(ExportOption(
                id: "web",
                title: "Send as a web page",
                detail: "One self-contained HTML file — the recipient needs no app.",
                systemImage: "safari",
                formatLabel: "HTML",
                estimatedBytes: ExportSizeEstimate.bytesWebViewer(
                    vertices: vertices, triangles: triangles, atlasBytes: atlasBytes),
                action: .webViewer))
            groups.append(ExportGroup(id: "share", title: "Share", options: share))

            groups.append(ExportGroup(id: "work", title: "Keep working on it", options: [
                ExportOption(
                    id: "edit-obj",
                    title: "Edit the geometry",
                    detail: "Plain text mesh every modelling tool reads. No colour.",
                    systemImage: "scissors",
                    formatLabel: "OBJ",
                    estimatedBytes: ExportSizeEstimate.bytes(mesh: vertices, triangles: triangles, format: .obj),
                    action: .mesh(.obj)),
                ExportOption(
                    id: "print-stl",
                    title: "3D print it",
                    detail: "The slicer standard — solid shape only, no colour.",
                    systemImage: "printer",
                    formatLabel: "STL",
                    estimatedBytes: ExportSizeEstimate.bytes(mesh: vertices, triangles: triangles, format: .stl),
                    action: .mesh(.stl)),
            ]))
        }

        if cloudPoints > 0 {
            var data: [ExportOption] = [
                ExportOption(
                    id: "ply-binary",
                    title: "Raw point data",
                    detail: "Positions and colour\(cloudHasNormals ? " and normals" : "") for MeshLab, CloudCompare, Poisson tools.",
                    systemImage: "circle.grid.3x3",
                    formatLabel: "PLY",
                    estimatedBytes: ExportSizeEstimate.bytes(points: cloudPoints, format: .plyBinary,
                                                            hasNormals: cloudHasNormals),
                    action: .cloud(.plyBinary)),
                ExportOption(
                    id: "ply-ascii",
                    title: "Readable point data",
                    detail: "The same points as plain text — bigger, but you can open it in an editor.",
                    systemImage: "doc.plaintext",
                    formatLabel: "PLY ASCII",
                    estimatedBytes: ExportSizeEstimate.bytes(points: cloudPoints, format: .plyASCII,
                                                            hasNormals: cloudHasNormals),
                    action: .cloud(.plyASCII)),
                ExportOption(
                    id: "csv",
                    title: "Spreadsheet / analysis",
                    detail: "One row per point — for Numbers, Excel, pandas.",
                    systemImage: "tablecells",
                    formatLabel: "CSV",
                    estimatedBytes: ExportSizeEstimate.bytes(points: cloudPoints, format: .csv,
                                                            hasNormals: false),
                    action: .cloud(.csv)),
            ]
            // Without a mesh the cloud IS the model, so it gets the AR + web
            // routes too rather than being filed away as raw data.
            if mesh == nil || mesh?.isEmpty == true {
                data.insert(ExportOption(
                    id: "points-usdz",
                    title: "View the points in AR",
                    detail: "The cloud as USDZ point geometry.",
                    systemImage: "arkit",
                    formatLabel: "USDZ",
                    estimatedBytes: ExportSizeEstimate.bytesPointUSDZ(points: cloudPoints),
                    action: .cloudUSDZ), at: 0)
                data.append(ExportOption(
                    id: "web-points",
                    title: "Send as a web page",
                    detail: "One self-contained HTML file — the recipient needs no app.",
                    systemImage: "safari",
                    formatLabel: "HTML",
                    estimatedBytes: ExportSizeEstimate.bytesWebViewer(
                        vertices: cloudPoints, triangles: 0, atlasBytes: 0),
                    action: .webViewer))
            }
            groups.append(ExportGroup(id: "data", title: "Point data", options: data))
        }

        return groups
    }
}
