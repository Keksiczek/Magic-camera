//
//  ModelStudioViewModel.swift
//  Magic Camera
//
//  State and operations for the standalone Model Studio screen: a stage of
//  named objects built from primitives and imported scans, edited by the
//  manual tools or by the on-device model through ModelStudioEngine. Every
//  mutating operation snapshots the stage first, so Undo steps back through
//  manual taps and chat commands alike, and returns a short factual result
//  string — the same honest-reporting contract as the scan Studio.
//

import SwiftUI
import simd

@MainActor
@Observable
final class ModelStudioViewModel {

    // MARK: - Stage state

    var objects: [StudioObject] = []
    var selectedID: UUID?

    /// Chat state (transcript reuses the scan Studio's line type).
    var transcript: [StudioLine] = []
    var isChatBusy = false

    /// True while a heavy operation (smooth/reduce/save) runs off-main.
    var isProcessing = false
    var toast: String?

    /// Set by UI to ask the renderer to re-frame the stage; it resets it.
    var frameRequest = false

    /// The FoundationModels session, type-erased (iOS 26+ only).
    @ObservationIgnored var chatSessionStorage: Any?

    /// A crash/quit snapshot found on first appearance, offered once. Nil when
    /// there is nothing to recover or the offer has been resolved.
    var pendingRecovery: Date?

    private var undoStack: [[StudioObject]] = []
    private var revisionCounter = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    init() {
        pendingRecovery = StudioAutoSave.pending()
    }

    var selectedObject: StudioObject? {
        guard let selectedID else { return nil }
        return objects.first { $0.id == selectedID }
    }

    var totalTriangles: Int { objects.reduce(0) { $0 + $1.mesh.triangleCount } }
    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(objects)
        if undoStack.count > 8 { undoStack.removeFirst() }
        scheduleAutosave()
    }

    // MARK: - Autosave

    /// Debounced snapshot of the stage to disk. Called from every mutation
    /// chokepoint (pushUndo) plus undo/load; the snapshot is captured ~1.5 s
    /// later so a burst of edits writes once.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            let box = UncheckedSendableBox(self.objects)
            Task.detached(priority: .utility) { StudioAutoSave.save(box.value) }
        }
    }

    /// Restores the autosaved stage found on appear (replacing the current,
    /// presumably empty, stage). The current stage still goes on the undo stack.
    func recoverAutosave() {
        pendingRecovery = nil
        loadStage(from: StudioAutoSave.url)
    }

    /// Dismisses the recovery offer; the snapshot stays until the next edit
    /// overwrites it, so a mis-tap isn't immediately destructive.
    func dismissRecovery() {
        pendingRecovery = nil
    }

    func undo() {
        guard !isProcessing, !isChatBusy, let snapshot = undoStack.popLast() else { return }
        // Fresh revisions force the renderer to rebuild restored nodes (their
        // cached geometry may be newer than the snapshot).
        objects = snapshot.map { object in
            var restored = object
            restored.revision = nextRevision()
            return restored
        }
        if let selectedID, !objects.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        scheduleAutosave()
        showToast("Undone")
    }

    private func nextRevision() -> Int {
        revisionCounter += 1
        return revisionCounter
    }

    // MARK: - Object lookup

    /// Resolves a tool/user reference to an object index: empty, "selected" or
    /// "it" mean the selection (or the only object); otherwise the names are
    /// matched case-insensitively (exact, then prefix, then substring).
    func resolveObject(_ reference: String?) -> Int? {
        let ref = (reference ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ref.isEmpty || ref == "selected" || ref == "it" || ref == "the selected object" {
            if let selectedID, let index = objects.firstIndex(where: { $0.id == selectedID }) {
                return index
            }
            return objects.count == 1 ? 0 : nil
        }
        if let exact = objects.firstIndex(where: { $0.name.lowercased() == ref }) { return exact }
        if let prefix = objects.firstIndex(where: { $0.name.lowercased().hasPrefix(ref) }) { return prefix }
        return objects.firstIndex { $0.name.lowercased().contains(ref) }
    }

    private func noSuchObject(_ reference: String?) -> String {
        guard !objects.isEmpty else { return "The stage is empty — add a shape first." }
        let names = objects.map(\.name).joined(separator: ", ")
        let ref = (reference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.isEmpty
            ? "Several objects are on stage — say which one: \(names)."
            : "No object called “\(ref)” — on stage: \(names)."
    }

    /// First free name for a shape: "Box", "Box 2", "Box 3"…
    private func uniqueName(for base: String) -> String {
        let existing = Set(objects.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base.lowercased()) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Creation

    /// Adds a primitive beside the current stage contents and selects it.
    @discardableResult
    func addPrimitive(_ shape: PrimitiveShape, size: SIMD3<Float>? = nil,
                      colorName: String? = nil, position: SIMD3<Float>? = nil) -> String {
        let dimensions = size ?? shape.defaultSize
        var mesh = PrimitiveMesher.mesh(shape, size: dimensions)
        guard !mesh.isEmpty else { return "Couldn't build the shape." }

        let palette = colorName.flatMap { StudioPalette.color(named: $0) }
        if let position {
            // Explicit placement (chat): the base footprint goes to (x, y, z),
            // y = 0 meaning on the ground. Primitives are built base-on-origin
            // and centred in X/Z, so a single translate lands them precisely —
            // letting the model build a multi-part object in one call per part.
            if position != .zero {
                mesh = mesh.transformed(by: Self.translation(position))
            }
        } else if let stageBox = stageBoundingBox(), let shapeBox = mesh.boundingBox() {
            // Auto-place beside the stage (manual "+" button — no position given).
            mesh = mesh.transformed(by: Self.translation(
                SIMD3(stageBox.max.x - shapeBox.min.x + 0.08, 0, 0)))
        }

        pushUndo()
        let object = StudioObject(name: uniqueName(for: shape.displayName), mesh: mesh,
                                  color: palette?.value ?? StudioPalette.defaultColor,
                                  colorName: palette?.name ?? StudioPalette.defaultName,
                                  revision: nextRevision())
        objects.append(object)
        selectedID = object.id
        let d = object.dimensions
        let c = object.center
        let summary = String(format: "Added %@ (%@, %.2f × %.2f × %.2f m) at (%.2f, %.2f, %.2f).",
                             object.name, object.colorName, d.x, d.y, d.z, c.x, c.y, c.z)
        showToast(summary)
        return summary
    }

    /// Brings a saved scan mesh onto the stage as a regular object, keeping
    /// its baked photo texture when one was saved (the .mcmesh format stores
    /// per-vertex UVs over the same mesh, so they survive any placement).
    func importMesh(_ mesh: MeshData, textured: TexturedMesh?, named name: String) {
        guard !mesh.isEmpty else { showToast("That mesh is empty"); return }
        var placed = mesh
        // Stand it on the ground beside the stage, like a new primitive.
        if let box = placed.boundingBox() {
            var offset = SIMD3<Float>(0, -box.min.y, 0)
            if let stageBox = stageBoundingBox() {
                offset.x = stageBox.max.x - box.min.x + 0.08
            } else {
                offset.x = -(box.min.x + box.max.x) / 2
                offset.z = -(box.min.z + box.max.z) / 2
            }
            placed = placed.transformed(by: Self.translation(offset))
        }
        var texture: StudioTexture?
        if let textured, textured.uvs.count == mesh.vertices.count {
            texture = StudioTexture(uvs: textured.uvs,
                                    texturePNG: textured.texturePNG,
                                    textureSize: textured.textureSize)
        }
        pushUndo()
        let object = StudioObject(name: uniqueName(for: name.isEmpty ? "Scan" : name),
                                  mesh: placed, texture: texture, revision: nextRevision())
        objects.append(object)
        selectedID = object.id
        frameRequest = true
        showToast(texture != nil
                  ? "Imported \(object.name) · \(placed.triangleCount) tris · textured"
                  : "Imported \(object.name) · \(placed.triangleCount) tris")
    }

    // MARK: - Transforms

    /// Commits a finished viewport drag: the renderer moved the node visually,
    /// this applies the same total offset to the geometry (one undo step).
    func commitDrag(id: UUID, offset: SIMD3<Float>) {
        guard simd_length(offset) > 1e-5,
              let index = objects.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        objects[index].mesh = objects[index].mesh.transformed(by: Self.translation(offset))
        objects[index].revision = nextRevision()
    }

    @discardableResult
    func moveObject(_ reference: String?, by offset: SIMD3<Float>) -> String {
        guard offset.x.isFinite, offset.y.isFinite, offset.z.isFinite,
              simd_length(offset) <= 100 else { return "That distance doesn't make sense." }
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        pushUndo()
        objects[index].mesh = objects[index].mesh.transformed(by: Self.translation(offset))
        objects[index].revision = nextRevision()
        let c = objects[index].center
        return String(format: "Moved %@ to (%.2f, %.2f, %.2f).",
                      objects[index].name, c.x, c.y, c.z)
    }

    /// Absolute placement: moves an object so its base footprint centre sits at
    /// `position` (y = 0 → on the ground). Easier for the model than computing a
    /// relative offset — it just states where the thing should go.
    @discardableResult
    func placeObject(_ reference: String?, at position: SIMD3<Float>) -> String {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              abs(position.x) <= 100, abs(position.y) <= 100, abs(position.z) <= 100 else {
            return "That position doesn't make sense."
        }
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        guard let box = objects[index].mesh.boundingBox() else { return "That object is empty." }
        let baseCentre = SIMD3<Float>((box.min.x + box.max.x) / 2, box.min.y,
                                      (box.min.z + box.max.z) / 2)
        let offset = position - baseCentre
        guard simd_length(offset) > 1e-5 else {
            return "\(objects[index].name) is already there."
        }
        pushUndo()
        objects[index].mesh = objects[index].mesh.transformed(by: Self.translation(offset))
        objects[index].revision = nextRevision()
        let c = objects[index].center
        return String(format: "Placed %@ at (%.2f, %.2f, %.2f).",
                      objects[index].name, c.x, c.y, c.z)
    }

    /// Relative placement: positions one object on top of / beside / in front of
    /// another, so the model can assemble parts ("head on top of body") without
    /// computing coordinates itself — the most error-prone step for the on-device
    /// model.
    @discardableResult
    func placeObject(_ reference: String?, relativeTo otherRef: String,
                     anchor: RelativeAnchor) -> String {
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        guard let otherIndex = resolveObject(otherRef) else { return noSuchObject(otherRef) }
        guard index != otherIndex else {
            return "Relative placement needs two different objects — “\(objects[index].name)” was named twice."
        }
        guard let box = objects[index].mesh.boundingBox(),
              let other = objects[otherIndex].mesh.boundingBox() else { return "That object is empty." }
        let ext = box.max - box.min
        let baseCentre = SIMD3<Float>((box.min.x + box.max.x) / 2, box.min.y,
                                      (box.min.z + box.max.z) / 2)
        let oCx = (other.min.x + other.max.x) / 2
        let oCz = (other.min.z + other.max.z) / 2
        let gap: Float = 0.02
        let target: SIMD3<Float>
        switch anchor {
        case .onTop:   target = SIMD3(oCx, other.max.y, oCz)                      // base on its top
        case .leftOf:  target = SIMD3(other.min.x - gap - ext.x / 2, other.min.y, oCz)
        case .rightOf, .beside: target = SIMD3(other.max.x + gap + ext.x / 2, other.min.y, oCz)
        case .inFront: target = SIMD3(oCx, other.min.y, other.max.z + gap + ext.z / 2)
        case .behind:  target = SIMD3(oCx, other.min.y, other.min.z - gap - ext.z / 2)
        }
        pushUndo()
        objects[index].mesh = objects[index].mesh.transformed(by: Self.translation(target - baseCentre))
        objects[index].revision = nextRevision()
        return "Placed \(objects[index].name) \(anchor.phrase) \(objects[otherIndex].name)."
    }

    @discardableResult
    func rotateObject(_ reference: String?, degreesY: Float) -> String {
        rotateObject(reference, degrees: degreesY, axis: SIMD3<Float>(0, 1, 0))
    }

    /// Rotates an object by `degrees` about the given axis, pivoting at its
    /// centre. Y is the common case (the chat tool and the turntable buttons);
    /// X/Z let the manual tools tip an object that was scanned lying down.
    @discardableResult
    func rotateObject(_ reference: String?, degrees: Float, axis: SIMD3<Float>) -> String {
        guard degrees.isFinite else { return "Rotation needs an angle in degrees." }
        let axisLength = simd_length(axis)
        guard axisLength > 1e-5 else { return "Rotation needs an axis." }
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        let radians = degrees * .pi / 180
        let rotate = simd_float4x4(simd_quatf(angle: radians, axis: axis / axisLength))
        pushUndo()
        let center = objects[index].center
        objects[index].mesh = objects[index].mesh
            .transformed(by: SpatialScanViewModel.aboutCenter(rotate, center: center))
        objects[index].revision = nextRevision()
        return String(format: "Rotated %@ by %.0f°.", objects[index].name, degrees)
    }

    @discardableResult
    func scaleObject(_ reference: String?, factor: Float) -> String {
        guard factor.isFinite, factor >= 0.05, factor <= 20 else {
            return "Scale factor must be between 0.05 and 20."
        }
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        var scale = matrix_identity_float4x4
        scale.columns.0.x = factor
        scale.columns.1.y = factor
        scale.columns.2.z = factor
        // Pivot at the footprint centre so the object stays on the ground.
        guard let box = objects[index].mesh.boundingBox() else { return "That object is empty." }
        let pivot = SIMD3<Float>((box.min.x + box.max.x) / 2, box.min.y,
                                 (box.min.z + box.max.z) / 2)
        pushUndo()
        objects[index].mesh = objects[index].mesh
            .transformed(by: SpatialScanViewModel.aboutCenter(scale, center: pivot))
        objects[index].revision = nextRevision()
        let d = objects[index].dimensions
        return String(format: "Scaled %@ by %.2f× — now %.2f × %.2f × %.2f m.",
                      objects[index].name, factor, d.x, d.y, d.z)
    }

    // MARK: - Appearance & lifecycle

    @discardableResult
    func recolorObject(_ reference: String?, colorName: String) -> String {
        guard let palette = StudioPalette.color(named: colorName) else {
            let names = StudioPalette.colors.map(\.name).joined(separator: ", ")
            return "Unknown colour “\(colorName)” — available: \(names)."
        }
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        pushUndo()
        let hadTexture = objects[index].texture != nil
        objects[index].color = palette.value
        objects[index].colorName = palette.name
        objects[index].texture = nil      // an explicit colour replaces the photos
        objects[index].revision = nextRevision()
        return hadTexture
            ? "Coloured \(objects[index].name) \(palette.name) — its photo texture was replaced."
            : "Coloured \(objects[index].name) \(palette.name)."
    }

    @discardableResult
    func duplicateObject(_ reference: String?) -> String {
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        let source = objects[index]
        let width = max(source.dimensions.x, 0.02)
        pushUndo()
        // Translation leaves UVs valid, so a photo texture rides along.
        let copy = StudioObject(name: uniqueName(for: source.name),
                                mesh: source.mesh.transformed(
                                    by: Self.translation(SIMD3(width + 0.08, 0, 0))),
                                color: source.color, colorName: source.colorName,
                                texture: source.texture,
                                revision: nextRevision())
        objects.append(copy)
        selectedID = copy.id
        return "Duplicated \(source.name) as \(copy.name)."
    }

    @discardableResult
    func deleteObject(_ reference: String?) -> String {
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        pushUndo()
        let removed = objects.remove(at: index)
        if selectedID == removed.id { selectedID = nil }
        return "Deleted \(removed.name)."
    }

    @discardableResult
    func mergeAll() -> String {
        guard objects.count > 1 else { return "There is nothing to merge — the stage has one object at most." }
        pushUndo()
        let merged = objects.reduce(MeshData()) { $0.appending($1.mesh) }
        let first = objects[0]
        let object = StudioObject(name: uniqueName(for: "Model"), mesh: merged,
                                  color: first.color, colorName: first.colorName,
                                  revision: nextRevision())
        objects = [object]
        selectedID = object.id
        return "Merged everything into \(object.name) (\(merged.triangleCount) triangles). It now has a single colour."
    }

    // MARK: - Boolean combine (CSG)

    /// Boolean-combines two objects (union / subtract / intersect) through the
    /// voxel CSG. The result replaces the first object (keeping its name and
    /// colour); the second is consumed.
    func combineObjects(_ refA: String?, with refB: String,
                        operation: MeshBoolean.Operation) async -> String {
        guard !isProcessing else { return "Another operation is still running." }
        guard let indexA = resolveObject(refA) else { return noSuchObject(refA) }
        guard let indexB = resolveObject(refB) else { return noSuchObject(refB) }
        guard indexA != indexB else {
            return "Combine needs two different objects — “\(objects[indexA].name)” was named twice."
        }
        let idA = objects[indexA].id
        let idB = objects[indexB].id
        let nameA = objects[indexA].name
        let nameB = objects[indexB].name

        isProcessing = true
        showToast(operation == .subtract ? "Carving \(nameB) out of \(nameA)…"
                                         : "Combining \(nameA) and \(nameB)…")
        let boxA = UncheckedSendableBox(objects[indexA].mesh)
        let boxB = UncheckedSendableBox(objects[indexB].mesh)
        // Photographs from either input are re-baked onto the resampled result.
        let sources = [objects[indexA].texturedMesh, objects[indexB].texturedMesh].compactMap { $0 }
        let sourcesBox = UncheckedSendableBox(sources)
        let result = await Task.detached(priority: .userInitiated)
        { () -> UncheckedSendableBox<(mesh: MeshData, textured: TexturedMesh?)?> in
            guard let combined = MeshBoolean.combine(boxA.value, boxB.value, operation: operation),
                  !combined.isEmpty else {
                let none: (mesh: MeshData, textured: TexturedMesh?)? = nil
                return UncheckedSendableBox(none)
            }
            let textured = sourcesBox.value.isEmpty
                ? nil : ModelStudioBaker.rebake(combined, fromSources: sourcesBox.value)
            let payload: (mesh: MeshData, textured: TexturedMesh?)? = (combined, textured)
            return UncheckedSendableBox(payload)
        }.value
        isProcessing = false

        guard let liveA = objects.firstIndex(where: { $0.id == idA }),
              objects.contains(where: { $0.id == idB }) else {
            return "The objects changed while combining — nothing was applied."
        }
        guard let outcome = result.value else {
            switch operation {
            case .intersect:
                return "\(nameA) and \(nameB) don't overlap — there is no intersection."
            case .subtract:
                return "Subtracting \(nameB) left nothing of \(nameA) (or the objects aren't solid)."
            case .union:
                return "Couldn't combine — the objects may not be solid surfaces."
            }
        }
        pushUndo()
        applyRetopologyResult(at: liveA, mesh: outcome.mesh, textured: outcome.textured)
        let combined = outcome.mesh
        objects.removeAll { $0.id == idB }
        selectedID = idA
        let summary: String
        switch operation {
        case .union:
            summary = "Joined \(nameB) into \(nameA) (\(combined.triangleCount) triangles)."
        case .subtract:
            summary = "Carved \(nameB) out of \(nameA) (\(combined.triangleCount) triangles)."
        case .intersect:
            summary = "Kept the overlap of \(nameA) and \(nameB) (\(combined.triangleCount) triangles)."
        }
        showToast(summary)
        return summary
    }

    // MARK: - Heavy mesh refinements

    func smoothObject(_ reference: String?) async -> String {
        await refineObject(reference, label: "Smoothing…") {
            MeshOptimizer.smooth($0.weldingDuplicateVertices())
        } report: { before, after in
            "Smoothed the surface; \(after) triangles (was \(before))."
        }
    }

    func reduceObject(_ reference: String?) async -> String {
        await refineObject(reference, label: "Reducing detail…") {
            MeshDecimator.decimate($0.weldingDuplicateVertices())
        } report: { before, after in
            "Reduced from \(before) to \(after) triangles."
        }
    }

    /// Shared runner for the background mesh refinements: resolve, snapshot,
    /// hop off-main, then re-find the object by id (the stage may have changed
    /// while the work ran) before swapping the result in. A photo texture is
    /// re-baked onto the new topology so smoothing/reducing a scan keeps its
    /// photographs (the work runs welded; the re-bake runs in the same task).
    private func refineObject(_ reference: String?, label: String,
                              _ work: @escaping @Sendable (MeshData) -> MeshData,
                              report: (Int, Int) -> String) async -> String {
        guard !isProcessing else { return "Another operation is still running." }
        guard let index = resolveObject(reference) else { return noSuchObject(reference) }
        let id = objects[index].id
        let before = objects[index].mesh.triangleCount
        isProcessing = true
        showToast(label)
        let box = UncheckedSendableBox(objects[index].mesh)
        let textureBox = UncheckedSendableBox(objects[index].texturedMesh)
        let result = await Task.detached(priority: .userInitiated)
        { () -> UncheckedSendableBox<(mesh: MeshData, textured: TexturedMesh?)> in
            let newMesh = work(box.value)
            let rebaked = textureBox.value.flatMap {
                newMesh.isEmpty ? nil : ModelStudioBaker.rebake(newMesh, fromSources: [$0])
            }
            let payload: (mesh: MeshData, textured: TexturedMesh?) = (newMesh, rebaked)
            return UncheckedSendableBox(payload)
        }.value
        isProcessing = false
        guard let liveIndex = objects.firstIndex(where: { $0.id == id }) else {
            return "The object was removed while processing."
        }
        guard !result.value.mesh.isEmpty else { return "The operation left no geometry — kept the original." }
        pushUndo()
        let after = result.value.mesh.triangleCount
        applyRetopologyResult(at: liveIndex, mesh: result.value.mesh, textured: result.value.textured)
        let summary = report(before, after)
        showToast(summary)
        return summary
    }

    /// Swaps in a re-topologised mesh, attaching a re-baked texture when one was
    /// produced (its UVs index the baker's duplicated-corner mesh, so that
    /// geometry becomes the object's) and clearing the stale texture otherwise.
    private func applyRetopologyResult(at index: Int, mesh: MeshData,
                                       textured: TexturedMesh?) {
        if let textured, textured.uvs.count == textured.mesh.vertices.count {
            objects[index].mesh = textured.mesh
            objects[index].texture = StudioTexture(uvs: textured.uvs,
                                                   texturePNG: textured.texturePNG,
                                                   textureSize: textured.textureSize)
        } else {
            objects[index].mesh = mesh
            objects[index].texture = nil
        }
        objects[index].revision = nextRevision()
    }

    // MARK: - Scene description

    func describeScene() -> String {
        guard !objects.isEmpty else { return "The stage is empty." }
        let lines = objects.map { object -> String in
            let d = object.dimensions
            let c = object.center
            return String(format: "%@ — %@, %.2f × %.2f × %.2f m, %d triangles, centre (%.2f, %.2f, %.2f)%@",
                          object.name, object.colorName, d.x, d.y, d.z,
                          object.mesh.triangleCount, c.x, c.y, c.z,
                          object.texture != nil ? ", photo-textured" : "")
        }
        return lines.joined(separator: "\n") + "\nTotal: \(objects.count) objects, \(totalTriangles) triangles."
    }

    // MARK: - Save / hand-off

    /// Merges the stage and saves it to the scan gallery (.mcmesh) with a
    /// palette texture so the object colours survive reload and export.
    func saveScene(named rawName: String) {
        guard !objects.isEmpty, !isProcessing else { return }
        isProcessing = true
        showToast("Saving…")
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? MeshStore.defaultName() : name
        let box = UncheckedSendableBox(objects)
        Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
                guard let baked = ModelStudioBaker.bake(box.value) else { return false }
                return (try? MeshStore.save(baked.mesh, textured: baked.textured,
                                            name: finalName)) != nil
            }.value
            guard let self else { return }
            self.isProcessing = false
            self.showToast(saved ? "Saved “\(finalName)” to the gallery"
                                 : "Couldn't save the model")
        }
    }

    // MARK: - Stage projects (.mcstage)

    /// Saves the whole stage — every object with its name and colour — as an
    /// editable project, unlike the gallery export which flattens to one mesh.
    func saveStage(named rawName: String) {
        guard !objects.isEmpty, !isProcessing else { return }
        isProcessing = true
        showToast("Saving project…")
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? StageStore.defaultName() : name
        let box = UncheckedSendableBox(objects)
        Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) {
                (try? StageStore.save(box.value, name: finalName)) != nil
            }.value
            guard let self else { return }
            self.isProcessing = false
            self.showToast(saved ? "Saved project “\(finalName)”"
                                 : "Couldn't save the project")
        }
    }

    /// Replaces the stage with a saved project. The current stage goes on the
    /// undo stack, so an accidental open is one tap to recover.
    func loadStage(from url: URL) {
        guard !isProcessing, !isChatBusy else { return }
        isProcessing = true
        showToast("Opening project…")
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                UncheckedSendableBox(try? StageStore.load(url))
            }.value
            guard let self else { return }
            self.isProcessing = false
            guard let stored = loaded.value, !stored.isEmpty else {
                self.showToast("Couldn't open the project")
                return
            }
            self.pushUndo()
            self.objects = stored.map { object in
                StudioObject(name: object.name, mesh: object.mesh,
                             color: object.color, colorName: object.colorName,
                             texture: object.texture, revision: self.nextRevision())
            }
            self.selectedID = nil
            self.frameRequest = true
            self.showToast("Opened “\(url.deletingPathExtension().lastPathComponent)” · \(stored.count) objects")
        }
    }

    /// Merges the stage and opens it in the Spatial Scan viewer (AR Quick Look,
    /// exports, measurement) via the same hand-off the home gallery uses.
    /// Consumes a mesh handed off from Spatial Scan ("Send to Studio") and drops
    /// it onto the stage beside whatever is already there. Called when Model
    /// Studio appears; a no-op when nothing is pending.
    func consumePendingScanImport() {
        guard case let .mesh(mesh, textured) = AppRouter.shared.consumeStudioImport() else { return }
        importMesh(mesh, textured: textured, named: "Scan")
    }

    func openInSpatialScan() {
        guard !objects.isEmpty, !isProcessing else { return }
        isProcessing = true
        let box = UncheckedSendableBox(objects)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated)
            { () -> UncheckedSendableBox<(MeshData, TexturedMesh?)>? in
                guard let baked = ModelStudioBaker.bake(box.value) else { return nil }
                return UncheckedSendableBox((baked.mesh, baked.textured))
            }.value
            guard let self else { return }
            self.isProcessing = false
            guard let result else { self.showToast("Nothing to open"); return }
            AppRouter.shared.openInSpatialScan(.mesh(result.value.0, result.value.1))
        }
    }

    // MARK: - Chat

    /// The assistant line currently being streamed into, if any.
    @ObservationIgnored private var streamingLineID: UUID?

    /// Sends one user sentence through the Model Studio engine. Each tool the
    /// model runs snapshots the stage itself, so Undo steps back per edit; the
    /// reply streams into a live bubble and tool results appear as they land.
    func runChatCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isChatBusy, !isProcessing else { return }
        transcript.append(StudioLine(role: .user, text: trimmed))
        isChatBusy = true
        streamingLineID = nil
        Task { [weak self] in
            guard let self else { return }
            let reply = await ModelStudioEngine.respond(to: trimmed, viewModel: self)
            // Finalise the streamed bubble with the definitive reply (they
            // normally match; the unavailable/error paths never streamed).
            if let id = self.streamingLineID,
               let index = self.transcript.firstIndex(where: { $0.id == id }) {
                self.transcript[index].text = reply
            } else {
                self.transcript.append(StudioLine(role: .assistant, text: reply))
            }
            self.streamingLineID = nil
            self.isChatBusy = false
        }
    }

    /// Streaming hook: updates (or starts) the live assistant bubble with the
    /// cumulative reply text so far.
    func chatStreamUpdate(_ text: String) {
        guard isChatBusy else { return }
        if let id = streamingLineID,
           let index = transcript.firstIndex(where: { $0.id == id }) {
            transcript[index].text = text
        } else {
            let line = StudioLine(role: .assistant, text: text)
            streamingLineID = line.id
            transcript.append(line)
        }
    }

    /// Appends one tool call's factual result as an activity row, so the user
    /// watches a multi-step build happen instead of staring at a spinner.
    func appendToolLine(_ text: String) {
        guard isChatBusy else { return }
        transcript.append(StudioLine(role: .tool, text: text))
    }

    // MARK: - Helpers

    private func stageBoundingBox() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var result: (min: SIMD3<Float>, max: SIMD3<Float>)?
        for object in objects {
            guard let box = object.mesh.boundingBox() else { continue }
            if let current = result {
                result = (simd_min(current.min, box.min), simd_max(current.max, box.max))
            } else {
                result = box
            }
        }
        return result
    }

    nonisolated static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(offset, 1)
        return m
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
