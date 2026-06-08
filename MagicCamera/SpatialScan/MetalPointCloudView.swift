//
//  MetalPointCloudView.swift
//  Magic Camera
//
//  SwiftUI wrapper around the Metal point-cloud renderer: an MTKView with an
//  arcball camera (drag = rotate, pinch = zoom, two-finger drag = pan), colour
//  modes, point size, framing presets and auto-orbit.
//

import MetalKit
import QuartzCore
import UIKit
import SwiftUI
import simd

struct MetalPointCloudView: UIViewRepresentable {
    let cloud: PointCloud
    var colorMode: PointColorMode
    var pointSize: CGFloat
    var autoOrbit: Bool
    @Binding var preset: CameraPreset?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let coordinator = context.coordinator
        let view = MTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.backgroundColor = .black
        view.preferredFramesPerSecond = 60

        guard let metal = MetalContext(),
              let renderer = PointCloudMetalRenderer(context: metal, colorPixelFormat: view.colorPixelFormat) else {
            return view
        }
        view.device = metal.device
        view.delegate = coordinator

        coordinator.renderer = renderer
        coordinator.colorMode = colorMode
        coordinator.pointSize = Float(pointSize)
        coordinator.autoOrbit = autoOrbit
        renderer.setCloud(cloud, colorMode: colorMode)
        coordinator.frameCamera(cloud: cloud)
        coordinator.attachGestures(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pointSize = Float(pointSize)
        coordinator.autoOrbit = autoOrbit
        if coordinator.colorMode != colorMode {
            coordinator.colorMode = colorMode
            coordinator.renderer?.setColorMode(colorMode, cloud: cloud)
        }
        if let preset {
            coordinator.applyPreset(preset, cloud: cloud)
            DispatchQueue.main.async { self.preset = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: PointCloudMetalRenderer?
        var camera = ArcballCamera()
        var colorMode: PointColorMode = .rgb
        var pointSize: Float = 6
        var autoOrbit = false
        private var lastTime = CACurrentMediaTime()

        func attachGestures(to view: MTKView) {
            let rotate = UIPanGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
            rotate.maximumNumberOfTouches = 1
            view.addGestureRecognizer(rotate)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)
        }

        func frameCamera(cloud: PointCloud) {
            guard let box = cloud.boundingBox() else { return }
            camera.frame(center: (box.min + box.max) * 0.5,
                         radius: max(simd_length(box.max - box.min) * 0.5, 0.1))
        }

        func applyPreset(_ preset: CameraPreset, cloud: PointCloud) {
            guard let box = cloud.boundingBox() else { return }
            camera.applyPreset(preset, center: (box.min + box.max) * 0.5,
                               radius: max(simd_length(box.max - box.min) * 0.5, 0.1))
        }

        @objc private func handleRotate(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            camera.rotate(dx: Float(t.x) * 0.006, dy: Float(t.y) * 0.006)
            g.setTranslation(.zero, in: g.view)
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            let scale = Float(1 / max(g.view?.bounds.height ?? 1, 1))
            camera.pan(dx: Float(t.x) * scale, dy: Float(t.y) * scale)
            g.setTranslation(.zero, in: g.view)
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            camera.zoom(scale: Float(g.scale))
            g.scale = 1
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            let now = CACurrentMediaTime()
            let dt = Float(now - lastTime)
            lastTime = now
            if autoOrbit && !UIAccessibility.isReduceMotionEnabled { camera.yaw += dt * 0.5 }
            renderer?.draw(in: view, camera: camera, pointSize: pointSize, edlEnabled: true)
        }
    }
}
