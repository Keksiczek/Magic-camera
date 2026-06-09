//
//  MeshExporter.swift
//  Magic Camera
//
//  Exports a MeshData to USDZ / OBJ / STL via ModelIO (built from SCNGeometry).
//

import ModelIO
import SceneKit
import SceneKit.ModelIO

enum MeshExporter {
    enum Format: String, CaseIterable, Identifiable {
        case usdz = "USDZ"
        case obj = "OBJ"
        case stl = "STL"
        case glb = "GLB (glTF)"
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .usdz: return "usdz"
            case .obj:  return "obj"
            case .stl:  return "stl"
            case .glb:  return "glb"
            }
        }
    }

    enum ExportError: LocalizedError {
        case empty, unsupported(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .empty:               return "Mesh is empty"
            case .unsupported(let e):  return "\(e) export not supported on this OS"
            case .failed(let m):       return m
            }
        }
    }

    static func write(_ mesh: MeshData, format: Format,
                      filename: String = "MagicCamera-mesh") throws -> URL {
        // GLB is serialised directly (ModelIO can't write glTF); the rest go
        // through ModelIO from an SCNGeometry.
        if format == .glb {
            return try MeshGLBExporter.write(mesh, filename: filename)
        }
        guard let geometry = MeshSceneBuilder.geometry(from: mesh) else { throw ExportError.empty }

        let mdlMesh = MDLMesh(scnGeometry: geometry)
        let asset = MDLAsset()
        asset.add(mdlMesh)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filename).\(format.fileExtension)")
        try? FileManager.default.removeItem(at: url)

        guard MDLAsset.canExportFileExtension(format.fileExtension) else {
            throw ExportError.unsupported(format.rawValue)
        }
        do {
            try asset.export(to: url)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        return url
    }
}
