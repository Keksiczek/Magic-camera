//
//  MetalDepthView.swift
//  Magic Camera
//
//  Bridges the Metal renderer + AR depth engine into SwiftUI via an MTKView.
//  The coordinator is the MTKView delegate: it draws the live preview and,
//  while recording, renders the same frame into the recorder's pixel buffer.
//

import MetalKit
import SwiftUI

struct MetalDepthView: UIViewRepresentable {
    let viewModel: LiveDepthCameraViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: viewModel.renderer?.device)
        view.colorPixelFormat = viewModel.renderer?.pixelFormat ?? .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.backgroundColor = .black
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private weak var viewModel: LiveDepthCameraViewModel?

        init(viewModel: LiveDepthCameraViewModel) {
            self.viewModel = viewModel
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let viewModel,
                  let renderer = viewModel.renderer else { return }
            viewModel.drawablePixelSize = view.drawableSize
            guard let frame = viewModel.engine.currentFrame else { return }

            renderer.draw(frame: frame, settings: viewModel.settings, in: view)

            if viewModel.isRecording,
               let recorder = viewModel.recorder,
               recorder.state == .recording,
               let buffer = recorder.dequeuePixelBuffer(),
               renderer.render(frame: frame, settings: viewModel.settings, into: buffer) {
                recorder.append(buffer, atSeconds: frame.timestamp)
            }
        }
    }
}
