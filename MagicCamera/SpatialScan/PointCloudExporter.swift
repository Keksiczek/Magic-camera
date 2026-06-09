//
//  PointCloudExporter.swift
//  Magic Camera
//
//  Serialises a PointCloud to PLY (binary or ASCII) or OBJ and writes it to a
//  temporary file for sharing/export. Pure Foundation, so it is unit-testable.
//

import Foundation
import simd

enum PointCloudExporter {
    enum Format: String, CaseIterable, Identifiable {
        case plyBinary = "PLY (binary)"
        case plyASCII = "PLY (ASCII)"
        case obj = "OBJ"
        case csv = "CSV"

        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .obj: return "obj"
            case .csv: return "csv"
            default:   return "ply"
            }
        }
    }

    enum ExportError: Error { case empty }

    /// Serialise to in-memory Data. When `normals` is supplied (and its count
    /// matches the cloud), PLY output includes per-vertex `nx ny nz` — useful for
    /// downstream surface reconstruction in MeshLab/Blender/Poisson tooling.
    static func data(from cloud: PointCloud, format: Format,
                     normals: [SIMD3<Float>]? = nil) throws -> Data {
        guard !cloud.isEmpty else { throw ExportError.empty }
        let validNormals = (normals?.count == cloud.count) ? normals : nil
        switch format {
        case .plyBinary: return plyBinary(cloud, normals: validNormals)
        case .plyASCII:  return plyASCII(cloud, normals: validNormals)
        case .obj:       return obj(cloud)
        case .csv:       return csv(cloud)
        }
    }

    /// Serialise and write to a temp file, returning its URL.
    static func write(_ cloud: PointCloud, format: Format,
                      filename: String = "MagicCamera-scan",
                      normals: [SIMD3<Float>]? = nil) throws -> URL {
        let payload = try data(from: cloud, format: format, normals: normals)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filename).\(format.fileExtension)")
        try? FileManager.default.removeItem(at: url)
        try payload.write(to: url)
        return url
    }

    // MARK: - PLY

    private static func plyHeader(count: Int, binary: Bool, hasNormals: Bool) -> String {
        let format = binary ? "binary_little_endian 1.0" : "ascii 1.0"
        let normalProps = hasNormals ? """
        property float nx
        property float ny
        property float nz

        """ : ""
        return """
        ply
        format \(format)
        comment Created by Magic Camera
        element vertex \(count)
        property float x
        property float y
        property float z
        \(normalProps)property uchar red
        property uchar green
        property uchar blue
        end_header

        """
    }

    private static func plyBinary(_ cloud: PointCloud, normals: [SIMD3<Float>]?) -> Data {
        var data = Data(plyHeader(count: cloud.count, binary: true, hasNormals: normals != nil).utf8)
        data.reserveCapacity(data.count + cloud.count * (normals != nil ? 27 : 15))
        for i in 0..<cloud.count {
            let p = cloud.positions[i]
            appendFloatLE(p.x, to: &data)
            appendFloatLE(p.y, to: &data)
            appendFloatLE(p.z, to: &data)
            if let normals {
                let nrm = normals[i]
                appendFloatLE(nrm.x, to: &data)
                appendFloatLE(nrm.y, to: &data)
                appendFloatLE(nrm.z, to: &data)
            }
            let c = colorBytes(cloud.colors[i])
            data.append(contentsOf: [c.0, c.1, c.2])
        }
        return data
    }

    private static func plyASCII(_ cloud: PointCloud, normals: [SIMD3<Float>]?) -> Data {
        var text = plyHeader(count: cloud.count, binary: false, hasNormals: normals != nil)
        text.reserveCapacity(text.count + cloud.count * (normals != nil ? 48 : 24))
        for i in 0..<cloud.count {
            let p = cloud.positions[i]
            let c = colorBytes(cloud.colors[i])
            if let normals {
                let nrm = normals[i]
                text += "\(p.x) \(p.y) \(p.z) \(nrm.x) \(nrm.y) \(nrm.z) \(c.0) \(c.1) \(c.2)\n"
            } else {
                text += "\(p.x) \(p.y) \(p.z) \(c.0) \(c.1) \(c.2)\n"
            }
        }
        return Data(text.utf8)
    }

    // MARK: - OBJ

    private static func obj(_ cloud: PointCloud) -> Data {
        var text = "# Created by Magic Camera\n"
        text.reserveCapacity(cloud.count * 28)
        for i in 0..<cloud.count {
            let p = cloud.positions[i]
            let c = cloud.colors[i]
            // "v x y z r g b" — vertex colours are a widely-read OBJ extension.
            text += "v \(p.x) \(p.y) \(p.z) \(c.x) \(c.y) \(c.z)\n"
        }
        return Data(text.utf8)
    }

    // MARK: - CSV

    private static func csv(_ cloud: PointCloud) -> Data {
        var text = "x,y,z,r,g,b,confidence\n"
        text.reserveCapacity(cloud.count * 32)
        for i in 0..<cloud.count {
            let p = cloud.positions[i]
            let c = colorBytes(cloud.colors[i])
            text += "\(p.x),\(p.y),\(p.z),\(c.0),\(c.1),\(c.2),\(cloud.confidences[i])\n"
        }
        return Data(text.utf8)
    }

    // MARK: - Helpers

    private static func appendFloatLE(_ value: Float, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func colorBytes(_ color: SIMD3<Float>) -> (UInt8, UInt8, UInt8) {
        let clamped = simd_clamp(color, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)) * 255
        return (UInt8(clamped.x.rounded()), UInt8(clamped.y.rounded()), UInt8(clamped.z.rounded()))
    }
}
