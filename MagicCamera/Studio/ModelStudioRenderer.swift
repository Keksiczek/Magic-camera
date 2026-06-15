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

/// The three translate handles shown on the selected object. Each axis node is
/// named so a hit test can tell which one the user grabbed.
private enum GizmoAxis: CaseIterable {
    case x, y, z

    var direction: SIMD3<Float> {
        switch self {
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }
    var nodeName: String {
        switch self {
        case .x: return "gizmo:x"
        case .y: return "gizmo:y"
        case .z: return "gizmo:z"
        }
    }
    static func from(name: String) -> GizmoAxis? {
        allCases.first { $0.nodeName == name }
    }
    var color: UIColor {
        switch self {
        case .x: return UIColor(red: 0.95, green: 0.30, blue: 0.35, alpha: 1)
        case .y: return UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 1)
        case .z: return UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1)
        }
    }
}

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
        scene.rootNode.addChildNode(coordinator.buildGizmo())

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
        // Translate-gizmo handles on the selected object. When a drag grabs a
        // handle, motion is constrained to that world axis (including vertical,
        // which the plane drag can't reach).
        private let gizmoRoot = SCNNode()
        private var draggedAxis: GizmoAxis?
        private var axisOrigin = SIMD3<Float>.zero
        private var axisDir = SIMD3<Float>.zero
        private var axisLastParam: Float = 0

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
            // Don't move the gizmo out from under an in-progress drag.
            if draggedID == nil { updateGizmo(objects: objects, selected: selected) }
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
            let location = recognizer.location(in: scnView)
            // A tap on a gizmo handle shouldn't deselect — keep the selection.
            if gizmoHit(at: location) != nil { return }
            // Tap on empty space (or the grid) deselects.
            selectedBinding?.wrappedValue = objectHit(at: location)?.id
        }

        // MARK: Viewport drag

        /// The drag pan begins only on an object; otherwise it fails and the
        /// camera recognizers (which wait on it) take over.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dragRecognizer, let scnView else { return true }
            guard dragEnabled else { return false }
            let location = gestureRecognizer.location(in: scnView)
            return gizmoHit(at: location) != nil || objectHit(at: location) != nil
        }

        @objc func handleDrag(_ recognizer: UIPanGestureRecognizer) {
            guard let scnView else { return }
            let location = recognizer.location(in: scnView)
            switch recognizer.state {
            case .began:
                dragTotal = .zero
                // Prefer a gizmo handle: an axis-constrained move of the selection
                // (the only way to move vertically).
                if let axis = gizmoHit(at: location), let id = selected, nodes[id] != nil {
                    draggedID = id
                    draggedAxis = axis
                    axisOrigin = SIMD3<Float>(gizmoRoot.position.x, gizmoRoot.position.y, gizmoRoot.position.z)
                    axisDir = simd_normalize(axis.direction)
                    axisLastParam = axisParameter(at: location, origin: axisOrigin, dir: axisDir) ?? 0
                    Haptics.impact(.light)
                    return
                }
                // Otherwise a free move across the object's horizontal plane.
                guard let hit = objectHit(at: location) else { return }
                draggedID = hit.id
                draggedAxis = nil
                dragPlaneY = hit.world.y
                dragLastPoint = planePoint(at: location, planeY: dragPlaneY) ?? hit.world
                selectedBinding?.wrappedValue = hit.id
                Haptics.impact(.light)
            case .changed:
                guard let id = draggedID, let node = nodes[id] else { return }
                let delta: SIMD3<Float>
                if draggedAxis != nil {
                    guard let u = axisParameter(at: location, origin: axisOrigin, dir: axisDir) else { return }
                    delta = axisDir * (u - axisLastParam)
                    axisLastParam = u
                } else {
                    guard let point = planePoint(at: location, planeY: dragPlaneY) else { return }
                    delta = point - dragLastPoint
                    dragLastPoint = point
                }
                dragTotal += delta
                node.position = SCNVector3(node.position.x + delta.x,
                                           node.position.y + delta.y,
                                           node.position.z + delta.z)
                gizmoRoot.position = SCNVector3(gizmoRoot.position.x + delta.x,
                                                gizmoRoot.position.y + delta.y,
                                                gizmoRoot.position.z + delta.z)
            case .ended:
                if let id = draggedID { onDragCommit?(id, dragTotal) }
                draggedID = nil
                draggedAxis = nil
            case .cancelled, .failed:
                // Put the node and the gizmo back — nothing was committed.
                if let id = draggedID { nodes[id]?.position = SCNVector3(0, 0, 0) }
                gizmoRoot.position = SCNVector3(gizmoRoot.position.x - dragTotal.x,
                                                gizmoRoot.position.y - dragTotal.y,
                                                gizmoRoot.position.z - dragTotal.z)
                draggedID = nil
                draggedAxis = nil
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

        // MARK: Gizmo

        /// Builds the three unit-length axis arrows once; `updateGizmo` then
        /// positions and scales the root onto the selected object.
        func buildGizmo() -> SCNNode {
            gizmoRoot.name = "gizmoRoot"
            for axis in GizmoAxis.allCases {
                let node = SCNNode()
                node.name = axis.nodeName
                let shaft = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 1.0))
                shaft.geometry?.firstMaterial = Self.gizmoMaterial(axis.color)
                shaft.position = SCNVector3(0, 0.5, 0)
                shaft.renderingOrder = 20
                node.addChildNode(shaft)
                let head = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.08, height: 0.28))
                head.geometry?.firstMaterial = Self.gizmoMaterial(axis.color)
                head.position = SCNVector3(0, 1.06, 0)
                head.renderingOrder = 20
                node.addChildNode(head)
                // Orient the +Y-built arrow along its world axis.
                switch axis {
                case .x: node.eulerAngles = SCNVector3(0, 0, -Float.pi / 2)
                case .y: break
                case .z: node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
                }
                gizmoRoot.addChildNode(node)
            }
            gizmoRoot.isHidden = true
            return gizmoRoot
        }

        private static func gizmoMaterial(_ color: UIColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.emission.contents = color
            // Draw on top of the object so the handles are always grabbable.
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            return material
        }

        /// Centres + sizes the gizmo on the selected object, or hides it.
        private func updateGizmo(objects: [StudioObject], selected: UUID?) {
            guard let selected, let object = objects.first(where: { $0.id == selected }) else {
                gizmoRoot.isHidden = true
                return
            }
            let center = object.center
            gizmoRoot.position = SCNVector3(center.x, center.y, center.z)
            let halfDiagonal = simd_length(object.dimensions) * 0.5
            let scale = min(max(halfDiagonal * 0.7, 0.05), 0.4)
            gizmoRoot.scale = SCNVector3(scale, scale, scale)
            gizmoRoot.isHidden = false
        }

        /// Which axis handle, if any, is under a screen point. Searches all hits
        /// (with depth ignored on the handles) so a handle in front of, or
        /// behind, the body is still grabbable.
        private func gizmoHit(at point: CGPoint) -> GizmoAxis? {
            guard let scnView, !gizmoRoot.isHidden else { return nil }
            let hits = scnView.hitTest(point, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue
            ])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, let axis = GizmoAxis.from(name: name) { return axis }
                    node = current.parent
                }
            }
            return nil
        }

        /// Parameter `u` along the line `origin + u·dir` of the point on that
        /// line closest to the screen point's view ray (nil when parallel) —
        /// the basis for axis-constrained dragging.
        private func axisParameter(at point: CGPoint, origin: SIMD3<Float>,
                                   dir: SIMD3<Float>) -> Float? {
            guard let scnView else { return nil }
            let near = scnView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let far = scnView.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            let rayOrigin = SIMD3<Float>(near.x, near.y, near.z)
            let rayDir = SIMD3<Float>(far.x - near.x, far.y - near.y, far.z - near.z)
            let w0 = rayOrigin - origin
            let a = simd_dot(rayDir, rayDir)
            let b = simd_dot(rayDir, dir)
            let c = simd_dot(dir, dir)
            let d = simd_dot(rayDir, w0)
            let e = simd_dot(dir, w0)
            let denom = a * c - b * b
            // Reject near-parallel (axis ≈ view ray): below this the parameter is
            // numerically unstable and would jump. Relative to a·c because the
            // ray length varies with the projection.
            guard a > 0, abs(denom) > a * c * 1e-4 else { return nil }
            return (a * e - b * d) / denom   // closest point on the axis line (see derivation)
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
