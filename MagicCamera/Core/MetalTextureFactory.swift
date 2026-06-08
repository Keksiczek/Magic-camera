//
//  MetalTextureFactory.swift
//  Magic Camera
//
//  Wraps a CVMetalTextureCache to turn CVPixelBuffers (camera planes, depth
//  map) into MTLTextures with zero copies.
//

import CoreVideo
import Metal

final class MetalTextureFactory {
    private let cache: CVMetalTextureCache

    init?(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { return nil }
        self.cache = cache
    }

    /// Create a texture for a single plane of a (possibly biplanar) buffer.
    func texture(from pixelBuffer: CVPixelBuffer,
                 pixelFormat: MTLPixelFormat,
                 planeIndex: Int) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        return makeTexture(pixelBuffer, pixelFormat, width, height, planeIndex)
    }

    /// Create a texture for a single-plane buffer (e.g. the depth map).
    func texture(from pixelBuffer: CVPixelBuffer,
                 pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return makeTexture(pixelBuffer, pixelFormat, width, height, 0)
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer,
                             _ format: MTLPixelFormat,
                             _ width: Int, _ height: Int,
                             _ planeIndex: Int) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            format, width, height, planeIndex, &cvTexture)
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return texture
    }

    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }
}
