//
//  PointCloudUSDZExporter.swift
//  Magic Camera
//
//  Exports a PointCloud to USDZ point geometry via ModelIO, so a captured cloud
//  can be opened in AR Quick Look and placed in the room — the same "View in AR"
//  path the mesh uses. Dense clouds are downsampled to keep the file light enough
//  for the system AR viewer.
//

import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import simd

enum PointCloudUSDZExporter {
    /// Upper bound on exported points; AR Quick Look stays responsive well below
    /// this, and the cloud is strided down evenly when it exceeds the cap.
    static let maxPoints = 200_000

    enum ExportError: LocalizedError {
        case empty
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .empty:          return "Point cloud is empty"
            case .failed(let m):  return m
            }
        }
    }

    static func write(_ cloud: PointCloud,
                      pointSize: CGFloat = 14,
                      filename: String = "MagicCamera-points") throws -> URL {
        guard !cloud.isEmpty else { throw ExportError.empty }

        let reduced = downsample(cloud, to: maxPoints)
        guard let geometry = PointCloudSceneBuilder.geometry(
            from: reduced, colorMode: .rgb, pointSize: pointSize) else {
            throw ExportError.empty
        }

        let asset = MDLAsset()
        asset.add(MDLMesh(scnGeometry: geometry))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filename).usdz")
        try? FileManager.default.removeItem(at: url)

        guard MDLAsset.canExportFileExtension("usdz") else {
            throw ExportError.failed("USDZ export unavailable on this OS")
        }
        do {
            try asset.export(to: url)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        return url
    }

    /// Evenly strides the cloud down to at most `cap` points.
    private static func downsample(_ cloud: PointCloud, to cap: Int) -> PointCloud {
        guard cloud.count > cap else { return cloud }
        let stride = Int((Double(cloud.count) / Double(cap)).rounded(.up))
        var out = PointCloud()
        var i = 0
        while i < cloud.count {
            out.append(position: cloud.positions[i],
                       color: cloud.colors[i],
                       confidence: cloud.confidences[i])
            i += stride
        }
        return out
    }
}
