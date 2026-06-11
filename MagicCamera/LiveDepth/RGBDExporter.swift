//
//  RGBDExporter.swift
//  Magic Camera
//
//  Exports the current AR frame as an RGBD capture: color.jpg (full camera
//  resolution, EXIF-oriented), depth.png (16-bit grayscale, millimetres,
//  0 = invalid) and capture.json with the camera intrinsics for both — enough
//  to unproject pixels into 3D in any DCC / CV tool. Pixel data stays in
//  native sensor orientation so depth, color and intrinsics line up exactly;
//  the EXIF flag merely orients the photo for display.
//

import ARKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum RGBDExporter {
    enum ExportError: LocalizedError {
        case noDepth
        case encodingFailed
        var errorDescription: String? {
            switch self {
            case .noDepth:        return "This frame carries no scene depth."
            case .encodingFailed: return "Couldn't encode the RGBD files."
            }
        }
    }

    /// Writes the three files into a fresh temp folder and returns their URLs
    /// (color, depth, metadata) for the share sheet.
    static func export(frame: ARFrame, orientation: CGImagePropertyOrientation) throws -> [URL] {
        guard let sceneDepth = frame.sceneDepth ?? frame.smoothedSceneDepth else {
            throw ExportError.noDepth
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagicCamera-RGBD-\(formatter.string(from: Date()))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let colorURL = folder.appendingPathComponent("color.jpg")
        let depthURL = folder.appendingPathComponent("depth.png")
        let metaURL = folder.appendingPathComponent("capture.json")

        try writeColor(frame.capturedImage, orientation: orientation, to: colorURL)
        let depthSize = try writeDepth(sceneDepth.depthMap, to: depthURL)
        try writeMetadata(camera: frame.camera, orientation: orientation,
                          depthSize: depthSize, to: metaURL)
        return [colorURL, depthURL, metaURL]
    }

    // MARK: - Color

    private static func writeColor(_ pixelBuffer: CVPixelBuffer,
                                   orientation: CGImagePropertyOrientation,
                                   to url: URL) throws {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
    }

    // MARK: - Depth

    /// 16-bit grayscale PNG, one millimetre per unit. Returns the depth map's
    /// pixel size for the metadata.
    private static func writeDepth(_ depthMap: CVPixelBuffer, to url: URL) throws -> CGSize {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            throw ExportError.encodingFailed
        }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        var millimetres = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let metres = row.loadUnaligned(fromByteOffset: x * 4, as: Float32.self)
                guard metres.isFinite, metres > 0 else { continue }
                millimetres[y * width + x] = UInt16(min(metres * 1000, 65_535))
            }
        }

        let data = millimetres.withUnsafeBufferPointer { Data(buffer: $0) }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearGray),
              let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 16, bitsPerPixel: 16,
                                    bytesPerRow: width * 2, space: space,
                                    bitmapInfo: bitmapInfo, provider: provider,
                                    decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encodingFailed }
        return CGSize(width: width, height: height)
    }

    // MARK: - Metadata

    private static func writeMetadata(camera: ARCamera, orientation: CGImagePropertyOrientation,
                                      depthSize: CGSize, to url: URL) throws {
        let intrinsics = camera.intrinsics
        let resolution = camera.imageResolution
        // The depth map is a uniformly scaled view of the color frame, so its
        // intrinsics are the color intrinsics times the resolution ratio.
        let scale = Double(depthSize.width) / Double(resolution.width)

        func intrinsicsDict(_ factor: Double) -> [String: Double] {
            [
                "fx": Double(intrinsics.columns.0.x) * factor,
                "fy": Double(intrinsics.columns.1.y) * factor,
                "cx": Double(intrinsics.columns.2.x) * factor,
                "cy": Double(intrinsics.columns.2.y) * factor,
            ]
        }

        let metadata: [String: Any] = [
            "format": "MagicCamera RGBD v1",
            "captured": ISO8601DateFormatter().string(from: Date()),
            "orientationEXIF": Int(orientation.rawValue),
            "note": "Pixel data is in native sensor orientation; the EXIF flag orients "
                + "the photo for display. Depth aligns with color after uniform scaling. "
                + "Depth unit: millimetres, 0 = invalid.",
            "color": [
                "file": "color.jpg",
                "width": Int(resolution.width),
                "height": Int(resolution.height),
                "intrinsics": intrinsicsDict(1),
            ] as [String: Any],
            "depth": [
                "file": "depth.png",
                "width": Int(depthSize.width),
                "height": Int(depthSize.height),
                "unit": "millimeter",
                "invalidValue": 0,
                "intrinsics": intrinsicsDict(scale),
            ] as [String: Any],
        ]
        let json = try JSONSerialization.data(withJSONObject: metadata,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: url, options: .atomic)
    }
}
