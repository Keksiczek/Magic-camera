//
//  MetalPointCloudView.swift
//  Magic Camera
//
//  SwiftUI wrapper around the Metal point-cloud renderer: an MTKView with an
//  arcball camera (drag = rotate, pinch = zoom, two-finger drag = pan), colour
//  modes, point size, framing presets and auto-orbit. In lasso mode a one-finger
//  drag instead traces a freeform loop; on release the enclosed points are
//  reported back (projected through the same camera the renderer draws with).
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
    /// When true, a one-finger drag traces a lasso instead of rotating.
    var lassoActive: Bool = false
    /// Reports the indices of `cloud` points enclosed by a finished lasso.
    var onLassoSelect: ([Int]) -> Void = { _ in }
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
        coordinator.cloud = cloud
        coordinator.colorMode = colorMode
        coordinator.pointSize = Float(pointSize)
        coordinator.autoOrbit = autoOrbit
        coordinator.onLassoSelect = onLassoSelect
        renderer.setCloud(cloud, colorMode: colorMode)
        coordinator.frameCamera(cloud: cloud)
        coordinator.attachGestures(to: view)
        coordinator.lassoActive = lassoActive
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pointSize = Float(pointSize)
        coordinator.autoOrbit = autoOrbit
        coordinator.cloud = cloud
        coordinator.onLassoSelect = onLassoSelect
        coordinator.lassoActive = lassoActive
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
        var cloud = PointCloud()
        var colorMode: PointColorMode = .rgb
        var pointSize: Float = 6
        var autoOrbit = false
        var onLassoSelect: ([Int]) -> Void = { _ in }
        var lassoActive = false { didSet { updateGestureEnablement() } }
        private var lastTime = CACurrentMediaTime()

        private weak var attachedView: MTKView?
        private var rotateGesture: UIPanGestureRecognizer?
        private var lassoGesture: UIPanGestureRecognizer?
        private var lassoPoints: [CGPoint] = []
        private var lassoLayer: CAShapeLayer?

        func attachGestures(to view: MTKView) {
            attachedView = view

            let rotate = UIPanGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
            rotate.maximumNumberOfTouches = 1
            view.addGestureRecognizer(rotate)
            rotateGesture = rotate

            let lasso = UIPanGestureRecognizer(target: self, action: #selector(handleLasso(_:)))
            lasso.maximumNumberOfTouches = 1
            lasso.isEnabled = false
            view.addGestureRecognizer(lasso)
            lassoGesture = lasso

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinch)
        }

        private func updateGestureEnablement() {
            rotateGesture?.isEnabled = !lassoActive
            lassoGesture?.isEnabled = lassoActive
            if !lassoActive { hideLassoLayer(); lassoPoints = [] }
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

        // MARK: - Lasso

        @objc private func handleLasso(_ g: UIPanGestureRecognizer) {
            guard let view = attachedView else { return }
            let point = g.location(in: view)
            switch g.state {
            case .began:
                lassoPoints = [point]
                showLassoLayer(in: view)
            case .changed:
                lassoPoints.append(point)
                updateLassoPath()
            case .ended:
                lassoPoints.append(point)
                finishLasso(in: view)
                hideLassoLayer()
            case .cancelled, .failed:
                hideLassoLayer()
                lassoPoints = []
            default:
                break
            }
        }

        /// Projects every point through the render camera and reports the ones
        /// inside the lasso polygon (view-point space, matching the gesture).
        private func finishLasso(in view: MTKView) {
            defer { lassoPoints = [] }
            let size = view.bounds.size
            guard lassoPoints.count >= 3, size.width > 0, size.height > 0 else { return }
            let viewProjection = camera.projectionMatrix(aspect: Float(size.width / size.height))
                * camera.viewMatrix()
            let polygon = lassoPoints
            var inside: [Int] = []
            for i in 0..<cloud.count {
                let p = cloud.positions[i]
                let clip = viewProjection * SIMD4<Float>(p.x, p.y, p.z, 1)
                guard clip.w > 1e-4 else { continue }      // behind the camera
                let sx = CGFloat(clip.x / clip.w * 0.5 + 0.5) * size.width
                let sy = CGFloat(0.5 - clip.y / clip.w * 0.5) * size.height
                if Self.pointInPolygon(CGPoint(x: sx, y: sy), polygon) { inside.append(i) }
            }
            onLassoSelect(inside)
        }

        /// Even-odd ray-cast point-in-polygon test.
        static func pointInPolygon(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
            var inside = false
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let a = polygon[i], b = polygon[j]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        private func showLassoLayer(in view: MTKView) {
            let layer = lassoLayer ?? CAShapeLayer()
            layer.strokeColor = UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1).cgColor
            layer.fillColor = UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 0.15).cgColor
            layer.lineWidth = 2
            layer.lineDashPattern = [6, 4]
            if lassoLayer == nil { view.layer.addSublayer(layer); lassoLayer = layer }
        }

        private func updateLassoPath() {
            guard let layer = lassoLayer, lassoPoints.count > 1 else { return }
            let path = UIBezierPath()
            path.move(to: lassoPoints[0])
            for p in lassoPoints.dropFirst() { path.addLine(to: p) }
            path.close()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = path.cgPath
            CATransaction.commit()
        }

        private func hideLassoLayer() {
            lassoLayer?.removeFromSuperlayer()
            lassoLayer = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            let now = CACurrentMediaTime()
            let dt = Float(now - lastTime)
            lastTime = now
            if autoOrbit && !lassoActive && !UIAccessibility.isReduceMotionEnabled { camera.yaw += dt * 0.5 }
            renderer?.draw(in: view, camera: camera, pointSize: pointSize, edlEnabled: true)
        }
    }
}
