//
//  RealityMeshPreview.swift
//  Magic Camera
//
//  The RealityKit half of the renderer migration: a plain orbit preview of a
//  built model, offered as an alternative to the SceneKit `MeshViewer`.
//
//  Scope is deliberate. `MeshViewer` also owns the ruler, the clip plane, walk
//  mode, ghost placement and camera presets — review tools built on SceneKit
//  hit-testing and node graphs. Reimplementing those blind, against a renderer
//  nothing in this app has run on device yet, is how a migration turns into a
//  regression. So this covers exactly the common case (shaded, textured, orbiting)
//  and `SpatialScanView` keeps SceneKit whenever a review tool is actually in use.
//  Once this is device-proven, the tools follow one at a time.
//
//  The camera is driven by hand rather than by `realityViewCameraControls`, which
//  is not available on iOS.
//

import SwiftUI
import simd
#if canImport(RealityKit)
import RealityKit
#endif

#if canImport(RealityKit)
@available(iOS 18.0, *)
struct RealityMeshPreview: View {
    let mesh: MeshData
    var textured: TexturedMesh? = nil
    var autoOrbit: Bool = false

    /// Orbit state, in the usual spherical terms around the model's centre.
    @State private var yaw: Float = .pi / 4
    @State private var pitch: Float = 0.35
    @State private var distanceScale: Float = 1
    @State private var dragStart: (yaw: Float, pitch: Float)?
    @State private var scaleStart: Float?
    @State private var buildFailed = false

    /// Radius that frames the whole model, and the point to orbit around.
    private var framing: (centre: SIMD3<Float>, radius: Float) {
        guard let box = (textured?.mesh ?? mesh).boundingBox() else {
            return (.zero, 1)
        }
        let centre = (box.min + box.max) / 2
        let radius = max(simd_length(box.max - box.min) / 2, 0.05)
        return (centre, radius)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RealityView { content in
                let (centre, radius) = framing
                do {
                    let model = try RealityMeshBuilder.entity(mesh: mesh, textured: textured)
                    // Orbit about the model's centre by moving the model to the
                    // origin, so the camera maths never has to know where it sat.
                    model.position = -centre
                    let pivot = Entity()
                    pivot.addChild(model)
                    content.add(pivot)
                } catch {
                    buildFailed = true
                }

                let camera = PerspectiveCamera()
                camera.camera.fieldOfViewInDegrees = 55
                camera.name = Self.cameraName
                content.add(camera)

                // Key light plus a soft fill: a baked-texture model needs almost
                // none, an untextured one needs enough to read its shape.
                let key = DirectionalLight()
                key.light.intensity = 2200
                key.light.isRealWorldProxy = true
                key.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
                content.add(key)
                content.add(makeFill(radius: radius))
            } update: { content in
                guard let camera = content.entities.first(where: { $0.name == Self.cameraName })
                else { return }
                let radius = framing.radius
                let distance = radius * 2.6 * distanceScale
                let clamped = max(min(pitch, 1.45), -1.45)
                let position = SIMD3<Float>(distance * cos(clamped) * sin(yaw),
                                            distance * sin(clamped),
                                            distance * cos(clamped) * cos(yaw))
                camera.position = position
                camera.look(at: .zero, from: position, relativeTo: nil)
            }
            .gesture(orbitGesture)
            .simultaneousGesture(zoomGesture)
            .onTapGesture(count: 2) { reset() }
            .task(id: autoOrbit) { await runAutoOrbit() }

            if buildFailed {
                Text("Couldn't show this model.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .accessibilityLabel("3D model preview")
        .accessibilityHint("Drag to orbit, pinch to zoom, double tap to reset the view.")
    }

    private static let cameraName = "preview-camera"

    private func makeFill(radius: Float) -> Entity {
        let fill = DirectionalLight()
        fill.light.intensity = 700
        fill.orientation = simd_quatf(angle: .pi / 2.4, axis: [0, 1, 0])
        return fill
    }

    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? (yaw, pitch)
                if dragStart == nil { dragStart = start }
                yaw = start.yaw - Float(value.translation.width) * 0.008
                pitch = start.pitch + Float(value.translation.height) * 0.008
            }
            .onEnded { _ in dragStart = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = scaleStart ?? distanceScale
                if scaleStart == nil { scaleStart = start }
                distanceScale = min(max(start / Float(value.magnification), 0.25), 6)
            }
            .onEnded { _ in scaleStart = nil }
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.25)) {
            yaw = .pi / 4
            pitch = 0.35
            distanceScale = 1
        }
    }

    /// Auto-orbit as a cancellable loop rather than an animation: `.task(id:)`
    /// tears it down the moment the toggle flips or the view goes away, which an
    /// infinitely repeating animation would not.
    private func runAutoOrbit() async {
        guard autoOrbit else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            guard dragStart == nil else { continue }   // never fight the finger
            yaw += 0.004
        }
    }
}
#endif
