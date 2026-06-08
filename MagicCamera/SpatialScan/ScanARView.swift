//
//  ScanARView.swift
//  Magic Camera
//
//  Live scanning surface. In point mode it forwards frames to the ScanRecorder
//  and shows a throttled point overlay; in mesh mode it enables LiDAR scene
//  reconstruction, collects mesh anchors, and shows a live wireframe.
//

import ARKit
import SceneKit
import SwiftUI

struct ScanARView: UIViewRepresentable {
    let viewModel: SpatialScanViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(recorder: viewModel.recorder, meshCollector: viewModel.meshCollector)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.automaticallyUpdatesLighting = true
        view.scene.rootNode.addChildNode(context.coordinator.overlayNode)
        context.coordinator.arView = view
        view.delegate = context.coordinator
        view.session.delegateQueue = context.coordinator.processingQueue
        view.session.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.update(capturing: viewModel.phase == .scanning,
                                   meshMode: viewModel.scanKind == .mesh)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSessionDelegate, ARSCNViewDelegate {
        private let recorder: ScanRecorder
        private let meshCollector: MeshAnchorCollector
        weak var arView: ARSCNView?
        let overlayNode = SCNNode()
        let processingQueue = DispatchQueue(label: "com.keks.MagicCamera.scanProcess")

        private let stateLock = NSLock()
        private var capturing = false
        private var meshMode = false
        private var lastOverlayUpdate: TimeInterval = 0
        private let overlayInterval: TimeInterval = 0.5

        init(recorder: ScanRecorder, meshCollector: MeshAnchorCollector) {
            self.recorder = recorder
            self.meshCollector = meshCollector
        }

        // MARK: - State sync (main thread)

        func update(capturing newCapturing: Bool, meshMode newMeshMode: Bool) {
            stateLock.lock()
            let wasCapturing = capturing
            capturing = newCapturing
            meshMode = newMeshMode
            stateLock.unlock()

            if newCapturing && !wasCapturing {
                overlayNode.geometry = nil
                runSession(meshEnabled: newMeshMode)
            }
        }

        private func runSession(meshEnabled: Bool) {
            guard let semantics = DeviceCapabilities.preferredDepthSemantics() else { return }
            let config = ARWorldTrackingConfiguration()
            config.frameSemantics = semantics
            config.worldAlignment = .gravity
            if meshEnabled && DeviceCapabilities.supportsSceneReconstruction {
                config.sceneReconstruction = .mesh
            }
            arView?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

        private var state: (capturing: Bool, meshMode: Bool) {
            stateLock.lock(); defer { stateLock.unlock() }
            return (capturing, meshMode)
        }

        // MARK: - ARSessionDelegate (point mode)

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let (isCapturing, isMesh) = state
            guard isCapturing, !isMesh else { return }
            recorder.process(frame: frame)
            maybeUpdateOverlay(at: frame.timestamp)
        }

        private func maybeUpdateOverlay(at time: TimeInterval) {
            stateLock.lock()
            let due = time - lastOverlayUpdate >= overlayInterval
            if due { lastOverlayUpdate = time }
            stateLock.unlock()
            guard due else { return }

            let cloud = recorder.snapshot()
            let geometry = PointCloudSceneBuilder.geometry(from: cloud, colorMode: .rgb, pointSize: 5)
            DispatchQueue.main.async { [weak self] in
                self?.overlayNode.geometry = geometry
            }
        }

        // MARK: - ARSCNViewDelegate (mesh mode)

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            applyMesh(node: node, anchor: anchor)
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            applyMesh(node: node, anchor: anchor)
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            if let meshAnchor = anchor as? ARMeshAnchor { meshCollector.remove(meshAnchor) }
        }

        private func applyMesh(node: SCNNode, anchor: ARAnchor) {
            let (isCapturing, isMesh) = state
            guard isCapturing, isMesh, let meshAnchor = anchor as? ARMeshAnchor else { return }
            meshCollector.update(meshAnchor)
            node.geometry = MeshSceneBuilder.wireframe(from: meshAnchor.geometry)
        }
    }
}
