//
//  MetalContext.swift
//  Magic Camera
//
//  Shared Metal foundation used by every renderer: the device, a command queue,
//  the default shader library and the texture factory. Both the live-effect pass
//  and the point-cloud renderer build on the same context.
//

import Metal

final class MetalContext: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let textureFactory: MetalTextureFactory

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let factory = MetalTextureFactory(device: device) else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.library = library
        self.textureFactory = factory
    }
}
