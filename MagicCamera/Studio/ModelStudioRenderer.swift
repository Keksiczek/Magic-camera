//
//  ModelStudioRenderer.swift
//  Magic Camera
//
//  SceneKit viewport for the Model Studio stage: one node per object (rebuilt
//  when its revision changes), a ground grid for orientation, free camera
//  control, and tap-to-select via hit testing. Selection is shown as a soft
//  emission tint so it works on any object colour.
//

import SceneKit
import simd
import SwiftUI
import UIKit

struct ModelStudioRenderer: UIViewRepresentable {
    var objects: [StudioObject]
    /// False while the view model is busy — blocks new drags so a commit can't
    /// race a running operation.
    var dragEnabled: Bool = true
    /// Called when a viewport drag ends, with the dragged object and its total
    /// world-space offset; the owner applies it to the geometry.
    var onDragCommit: (UUID, SIMD3<Float>) -> Void = { _, _ in }
    @Binding var selectedID: UUID?
    @Binding var frameRequest: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor.black
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene

        let coordinator = context.coordinator
        coordinator.scnView = scnView
        scene.rootNode.addChildNode(Self.gridNode())
        scene.rootNode.addChildNode(coordinator.objectsRoot)

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.001
        camera.zFar = 1000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        coordinator.cameraNode = cameraNode

        coordinator.selectedBinding = $selectedID
        coordinator.sync(objects: objects, selected: selectedID)
        coordinator.frame(objects)

        let tap = UITapGestureRecognizer(target: coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tap)

        // Object drag: a one-finger pan that begins only when the touch lands
        // on an object. The camera's own recognizers (installed by
        // allowsCameraControl above) wait for it to fail, so dragging empty
        // space still orbits.
        let drag = UIPanGestureRecognizer(target: coordinator,
                                          action: #selector(Coordinator.handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = coordinator
        scnView.addGestureRecognizer(drag)
        coordinator.dragRecognizer = drag
        scnView.gestureRecognizers?.forEach { existing in
            if existing !== drag && existing !== tap { existing.require(toFail: drag) }
        }
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selectedBinding = $selectedID
        coordinator.dragEnabled = dragEnabled
        coordinator.onDragCommit = onDragCommit
        coordinator.sync(objects: objects, selected: selectedID)
        if frameRequest {
            coordinator.frame(objects)
            DispatchQueue.main.async { self.frameRequest = false }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var scnView: SCNView?
        let objectsRoot = SCNNode()
        var cameraNode: SCNNode?
        var selectedBinding: Binding<UUID?>?
        weak var dragRecognizer: UIPanGestureRecognizer?
        var dragEnabled = true
        var onDragCommit: ((UUID, SIMD3<Float>) -> Void)?
        private var nodes: [UUID: SCNNode] = [:]
        private var revisions: [UUID: Int] = [:]
        private var selected: UUID?
        // Live drag state: the node is offset visually; the total offset is
        // committed to the geometry once on gesture end.
        private var draggedID: UUID?
        private var dragPlaneY: Float = 0
        private var dragLastPoint = SIMD3<Float>.zero
        private var dragTotal = SIMD3<Float>.zero

        /// Adds/rebuilds/removes object nodes to match the stage, then applies
        /// the selection highlight.
        func sync(objects: [StudioObject], selected: UUID?) {
            var seen = Set<UUID>()
            for object in objects {
                seen.insert(object.id)
                if nodes[object.id] != nil, revisions[object.id] == object.revision { continue }
                nodes[object.id]?.removeFromParentNode()
                let node = SCNNode(geometry: Self.geometry(for: object))
                node.name = object.id.uuidString
                objectsRoot.addChildNode(node)
                nodes[object.id] = node
                revisions[object.id] = object.revision
            }
            for (id, node) in nodes where !seen.contains(id) {
                node.removeFromParentNode()
                nodes[id] = nil
                revisions[id] = nil
            }
            self.selected = selected
            for (id, node) in nodes {
                // Dimmed accent as emission (not alpha — emission ignores it).
                node.geometry?.firstMaterial?.emission.contents = id == selected
                    ? UIColor(red: 0.13, green: 0.20, blue: 0.43, alpha: 1)
                    : UIColor.black
            }
        }

        private static func geometry(for object: StudioObject) -> SCNGeometry? {
            // Photo-textured objects (imported scans) show their atlas; the
            // rest take their solid palette colour.
            if let textured = object.texturedMesh,
               let geometry = TexturedMeshExporter.geometry(from: textured) {
                return geometry
            }
            guard let geometry = MeshSceneBuilder.geometry(from: object.mesh) else { return nil }
            let material = geometry.firstMaterial
            material?.lightingModel = .physicallyBased
            material?.diffuse.contents = UIColor(red: CGFloat(object.color.x),
                                                 green: CGFloat(object.color.y),
                                                 blue: CGFloat(object.color.z), alpha: 1)
            material?.roughness.contents = 0.55
            material?.isDoubleSided = true
            return geometry
        }

        /// Positions the camera to comfortably frame the whole stage.
        func frame(_ objects: [StudioObject]) {
            guard let cameraNode else { return }
            var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
            for object in objects {
                guard let box = object.mesh.boundingBox() else { continue }
                if let current = bounds {
                    bounds = (simd_min(current.min, box.min), simd_max(current.max, box.max))
                } else {
                    bounds = box
                }
            }
            let center: SIMD3<Float>
            let radius: Float
            if let bounds {
                center = (bounds.min + bounds.max) * 0.5
                radius = max(simd_length(bounds.max - bounds.min) * 0.5, 0.15)
            } else {
                center = SIMD3<Float>(0, 0.1, 0)
                radius = 0.35
            }
            let eye = center + SIMD3<Float>(0.85, 0.8, 1.1) * radius * 2.2
            cameraNode.position = SCNVector3(eye.x, eye.y, eye.z)
            cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scnView else { return }
            // Tap on empty space (or the grid) deselects.
            selectedBinding?.wrappedValue = objectHit(at: recognizer.location(in: scnView))?.id
        }

        // MARK: Viewport drag

        /// The drag pan begins only on an object; otherwise it fails and the
        /// camera recognizers (which wait on it) take over.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dragRecognizer, let scnView else { return true }
            guard dragEnabled else { return false }
            return objectHit(at: gestureRecognizer.location(in: scnView)) != nil
        }

        @objc func handleDrag(_ recognizer: UIPanGestureRecognizer) {
            guard let scnView else { return }
            let location = recognizer.location(in: scnView)
            switch recognizer.state {
            case .began:
                guard let hit = objectHit(at: location) else { return }
                draggedID = hit.id
                dragPlaneY = hit.world.y
                dragLastPoint = planePoint(at: location, planeY: dragPlaneY) ?? hit.world
                dragTotal = .zero
                selectedBinding?.wrappedValue = hit.id
                Haptics.impact(.light)
            case .changed:
                guard let id = draggedID, let node = nodes[id],
                      let point = planePoint(at: location, planeY: dragPlaneY) else { return }
                let delta = point - dragLastPoint
                dragLastPoint = point
                dragTotal += delta
                node.position = SCNVector3(node.position.x + delta.x,
                                           node.position.y + delta.y,
                                           node.position.z + delta.z)
            case .ended:
                if let id = draggedID { onDragCommit?(id, dragTotal) }
                draggedID = nil
            case .cancelled, .failed:
                // Put the node back — nothing was committed.
                if let id = draggedID { nodes[id]?.position = SCNVector3(0, 0, 0) }
                draggedID = nil
            default:
                break
            }
        }

        /// Closest object under a screen point, with the hit's world position.
        private func objectHit(at point: CGPoint) -> (id: UUID, world: SIMD3<Float>)? {
            guard let scnView else { return nil }
            let hits = scnView.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue
            ])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, let id = UUID(uuidString: name),
                       nodes[id] != nil {
                        let w = hit.worldCoordinates
                        return (id, SIMD3<Float>(w.x, w.y, w.z))
                    }
                    node = current.parent
                }
            }
            return nil
        }

        /// Intersection of the screen point's view ray with the horizontal
        /// plane y = planeY — the drag surface.
        private func planePoint(at point: CGPoint, planeY: Float) -> SIMD3<Float>? {
            guard let scnView else { return nil }
            let near = scnView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let far = scnView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            let direction = SIMD3<Float>(far.x - near.x, far.y - near.y, far.z - near.z)
            guard abs(direction.y) > 1e-5 else { return nil }
            let t = (planeY - near.y) / direction.y
            guard t > 0 else { return nil }
            return SIMD3<Float>(near.x, near.y, near.z) + direction * t
        }
    }

    /// Subtle 2 × 2 m ground grid (10 cm cells) so scale and the ground plane
    /// read at a glance.
    private static func gridNode() -> SCNNode {
        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        let extent: Float = 1.0
        let step: Float = 0.1
        var coordinate = -extent
        while coordinate <= extent + 1e-4 {
            let i = UInt32(vertices.count)
            vertices.append(SCNVector3(coordinate, 0, -extent))
            vertices.append(SCNVector3(coordinate, 0, extent))
            vertices.append(SCNVector3(-extent, 0, coordinate))
            vertices.append(SCNVector3(extent, 0, coordinate))
            indices.append(contentsOf: [i, i + 1, i + 2, i + 3])
            coordinate += step
        }
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(white: 1, alpha: 0.10)
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }
}
