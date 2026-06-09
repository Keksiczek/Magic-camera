//
//  TurntableVideoBuilder.swift
//  Magic Camera
//
//  Renders a captured mesh spinning on a turntable to a looping .mp4 for sharing.
//  Uses an offscreen SCNRenderer (snapshot is thread-safe) so it runs on a
//  background task, and encodes frames with AVAssetWriter.
//

import AVFoundation
import CoreVideo
import Metal
import SceneKit
import simd
import UIKit

enum TurntableVideoBuilder {
    private static let frameCount = 90
    private static let fps: Int32 = 30

    static func make(mesh: MeshData, colorMode: MeshColorMode, size: CGSize) async -> URL? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let geometry = MeshSceneBuilder.geometry(from: mesh, colorMode: colorMode),
              let box = mesh.boundingBox() else { return nil }
        let width = Int(size.width) & ~1
        let height = Int(size.height) & ~1
        guard width > 0, height > 0 else { return nil }

        let scene = SCNScene()
        scene.background.contents = UIColor.black

        let spin = SCNNode()
        let meshNode = SCNNode(geometry: geometry)
        let center = (box.min + box.max) * 0.5
        meshNode.simdPosition = -center                // spin about the model centre
        spin.addChildNode(meshNode)
        scene.rootNode.addChildNode(spin)

        let radius = max(simd_length(box.max - box.min) * 0.5, 0.1)
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.001
        camera.zFar = 1000
        cameraNode.camera = camera
        cameraNode.simdPosition = SIMD3<Float>(0, radius * 0.35, radius * 2.6)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(light(.ambient, intensity: 500))
        let key = light(.directional, intensity: 850)
        key.eulerAngles = SCNVector3(-0.9, 0.4, 0)
        scene.rootNode.addChildNode(key)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode

        guard let (writer, input, adaptor) = makeWriter(width: width, height: height) else { return nil }
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { writer.cancelWriting(); return nil }

        let renderSize = CGSize(width: width, height: height)
        for i in 0..<frameCount {
            spin.eulerAngles = SCNVector3(0, 2 * Float.pi * Float(i) / Float(frameCount), 0)
            let image = renderer.snapshot(atTime: TimeInterval(i) / TimeInterval(fps),
                                          with: renderSize, antialiasingMode: .multisampling4X)
            guard let buffer = pixelBuffer(from: image, pool: pool, width: width, height: height) else { continue }
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()

        let writerBox = UncheckedSendableBox(writer)
        let url = writer.outputURL
        return await withCheckedContinuation { continuation in
            writerBox.value.finishWriting {
                continuation.resume(returning: writerBox.value.status == .completed ? url : nil)
            }
        }
    }

    // MARK: - Helpers

    private static func light(_ type: SCNLight.LightType, intensity: CGFloat) -> SCNNode {
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        let node = SCNNode()
        node.light = light
        return node
    }

    private static func makeWriter(width: Int, height: Int)
        -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MagicCamera-turntable-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return (writer, input, adaptor)
    }

    private static func pixelBuffer(from image: UIImage, pool: CVPixelBufferPool,
                                    width: Int, height: Int) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let context = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}
