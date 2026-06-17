//
//  RoomCombinedView.swift
//  Magic Camera
//
//  Shows a RoomPlan room and its hybrid walkthrough point cloud TOGETHER in one
//  orbitable scene. Both were captured in the same ARKit world space during the
//  same walkthrough, so they line up without any registration. Layers toggle
//  independently, and the cloud can be reconstructed into a surface draped over
//  the parametric room (the "make a surface and lay it over the room" flow).
//

import SceneKit
import SwiftUI
import simd
import UIKit

// MARK: - SceneKit overlay

/// Orbitable scene holding the room mesh, the point cloud and an optional
/// reconstructed surface as independently toggleable layers.
struct RoomCombinedView: UIViewRepresentable {
    let roomMesh: MeshData
    let cloud: PointCloud
    var surface: MeshData?
    var showRoom: Bool
    var showPoints: Bool
    var showSurface: Bool
    var roomColorMode: MeshColorMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.scene = SCNScene()

        let c = context.coordinator
        c.view = view
        c.rebuild(roomMesh: roomMesh, cloud: cloud, surface: surface, roomColorMode: roomColorMode)
        c.frameCamera(on: roomMesh.boundingBox() ?? cloud.boundingBox())
        c.apply(showRoom: showRoom, showPoints: showPoints, showSurface: showSurface)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        c.rebuild(roomMesh: roomMesh, cloud: cloud, surface: surface, roomColorMode: roomColorMode)
        c.apply(showRoom: showRoom, showPoints: showPoints, showSurface: showSurface)
    }

    @MainActor
    final class Coordinator {
        weak var view: SCNView?
        private var roomNode: SCNNode?
        private var pointsNode: SCNNode?
        private var surfaceNode: SCNNode?
        private var builtRoomMode: MeshColorMode?
        private var builtSurfaceCount = -1
        private var framed = false

        func rebuild(roomMesh: MeshData, cloud: PointCloud, surface: MeshData?,
                     roomColorMode: MeshColorMode) {
            guard let scene = view?.scene else { return }
            // Room — rebuild only when its colour mode changes.
            if roomNode == nil || builtRoomMode != roomColorMode {
                roomNode?.removeFromParentNode()
                if !roomMesh.isEmpty {
                    let node = MeshSceneBuilder.node(from: roomMesh, colorMode: roomColorMode)
                    scene.rootNode.addChildNode(node)
                    roomNode = node
                }
                builtRoomMode = roomColorMode
            }
            // Points — built once.
            if pointsNode == nil, cloud.count > 0 {
                let node = PointCloudSceneBuilder.node(from: cloud, colorMode: .rgb, pointSize: 6)
                scene.rootNode.addChildNode(node)
                pointsNode = node
            }
            // Surface — rebuilt when a new reconstruction arrives.
            let surfCount = surface?.count ?? -1
            if surfCount != builtSurfaceCount {
                surfaceNode?.removeFromParentNode()
                surfaceNode = nil
                if let surface, !surface.isEmpty {
                    let node = MeshSceneBuilder.node(from: surface, colorMode: .shaded)
                    scene.rootNode.addChildNode(node)
                    surfaceNode = node
                }
                builtSurfaceCount = surfCount
            }
        }

        func apply(showRoom: Bool, showPoints: Bool, showSurface: Bool) {
            roomNode?.isHidden = !showRoom
            pointsNode?.isHidden = !showPoints
            surfaceNode?.isHidden = !showSurface
        }

        /// Frames the camera on the room's bounds, pulled back and slightly up so
        /// the whole space is visible; orbit control then takes over.
        func frameCamera(on box: (min: SIMD3<Float>, max: SIMD3<Float>)?) {
            guard !framed, let box, let scene = view?.scene else { return }
            framed = true
            let center = (box.min + box.max) * 0.5
            let radius = max(simd_length(box.max - box.min) * 0.5, 0.5)

            let cameraNode = SCNNode()
            let camera = SCNCamera()
            camera.zNear = 0.01
            camera.zFar = Double(radius) * 20 + 100
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(center.x, center.y + radius * 0.6, center.z + radius * 2.2)
            cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
            scene.rootNode.addChildNode(cameraNode)
            view?.pointOfView = cameraNode
        }
    }
}

// MARK: - SwiftUI review screen

/// Full-screen combined review presented from the RoomPlan done panel. Loads the
/// walkthrough cloud off-main, overlays it on the room, and offers a bounded
/// surface reconstruction the user can save on its own.
struct RoomCombinedReview: View {
    let roomMesh: MeshData
    let recorder: ScanRecorder
    @Environment(\.dismiss) private var dismiss

    @State private var cloud: PointCloud?
    @State private var surface: MeshData?
    @State private var showRoom = true
    @State private var showPoints = true
    @State private var showSurface = false
    @State private var roomColorMode: MeshColorMode = .classification
    @State private var reconstructing = false
    @State private var savingSurface = false
    @State private var savedSurface = false
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cloud {
                RoomCombinedView(roomMesh: roomMesh, cloud: cloud, surface: surface,
                                 showRoom: showRoom, showPoints: showPoints,
                                 showSurface: showSurface, roomColorMode: roomColorMode)
                    .ignoresSafeArea()
                overlay(cloud: cloud)
            } else {
                ProgressView("Loading walkthrough points…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .task { await loadCloud() }
    }

    // MARK: Controls

    @ViewBuilder
    private func overlay(cloud: PointCloud) -> some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                StatusBadge(text: "\(MeasurementFormat.count(roomMesh.triangleCount)) tris · "
                            + "\(MeasurementFormat.count(cloud.count)) pts",
                            systemImage: "square.stack.3d.up")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    layerChip("Room", "house.fill", on: showRoom) { showRoom.toggle() }
                    layerChip("Points", "circle.grid.3x3.fill", on: showPoints) { showPoints.toggle() }
                    if surface != nil {
                        layerChip("Surface", "drop.fill", on: showSurface) { showSurface.toggle() }
                    }
                }
                if showRoom {
                    HStack(spacing: 10) {
                        layerChip("Surfaces", "paintpalette",
                                  on: roomColorMode == .classification) {
                            roomColorMode = roomColorMode == .classification ? .shaded : .classification
                        }
                    }
                }

                if surface == nil {
                    Button { reconstructSurface(cloud) } label: {
                        actionLabel(reconstructing ? "Building surface…" : "Reconstruct surface from points",
                                    system: "wand.and.stars", busy: reconstructing,
                                    fill: Theme.accent, fg: .black)
                    }
                    .buttonStyle(.plain)
                    .disabled(reconstructing)
                } else {
                    Button { saveSurface() } label: {
                        actionLabel(savingSurface ? "Saving…"
                                    : savedSurface ? "Surface saved" : "Save surface to library",
                                    system: savedSurface ? "checkmark" : "tray.and.arrow.down",
                                    busy: savingSurface, fill: Theme.surface, fg: Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(savingSurface || savedSurface)
                }

                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(14)
            .glassPanel()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func layerChip(_ title: String, _ system: String, on: Bool,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(on ? Theme.accent.opacity(0.9) : Theme.surface,
                            in: Capsule())
                .foregroundStyle(on ? .black : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ text: String, system: String, busy: Bool,
                             fill: Color, fg: Color) -> some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small).tint(fg) }
            else { Image(systemName: system) }
            Text(text)
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
        .foregroundStyle(fg)
    }

    // MARK: Work

    private func loadCloud() async {
        guard cloud == nil else { return }
        let recorder = recorder
        let snap = await Task.detached(priority: .userInitiated) {
            recorder.snapshotDenoised(minNeighbors: 2).cloud
        }.value
        cloud = snap
        if snap.isEmpty { note = "No usable walkthrough points were captured." }
    }

    /// Coarse, bounded reconstruction — a room cloud is huge, so it's subsampled
    /// hard before meshing to stay finite (the surface is for draping/comparison,
    /// not fine detail).
    private func reconstructSurface(_ cloud: PointCloud) {
        reconstructing = true
        note = nil
        let box = UncheckedSendableBox(cloud)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> MeshData? in
                var working = box.value
                let resolution = 48
                let sample = working.reconstructionSampleIndices(resolution: resolution,
                                                                 maxPoints: 120_000)
                if sample.count >= 100 && sample.count < working.count {
                    working = working.subset(sample)
                }
                guard working.count > 500 else { return nil }
                let normals = PointCloudNormals.estimateConsistent(working)
                return SmoothSurfaceReconstructor.reconstruct(working, resolution: resolution,
                                                              normals: normals)
                    ?? PointCloudMesher.reconstruct(working, resolution: resolution)
            }.value
            reconstructing = false
            if let result, !result.isEmpty {
                surface = result
                showSurface = true
                showPoints = false      // show the new surface in place of raw points
                note = "Surface ready · \(MeasurementFormat.count(result.triangleCount)) tris"
            } else {
                note = "Couldn't build a surface from these points."
            }
        }
    }

    private func saveSurface() {
        guard let surface, !savedSurface, !savingSurface else { return }
        savingSurface = true
        let box = UncheckedSendableBox(surface)
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                try? MeshStore.save(box.value, textured: nil,
                                    name: "Room surface \(Self.dateStamp())")
            }.value
            savingSurface = false
            if let url {
                if let png = ThumbnailRenderer.png(for: box.value) { Thumbnails.write(png, for: url) }
                savedSurface = true
                note = "Saved — find it in Spatial Scan ▸ gallery."
            } else {
                note = "Surface save failed."
            }
        }
    }

    private nonisolated static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f.string(from: Date())
    }
}
