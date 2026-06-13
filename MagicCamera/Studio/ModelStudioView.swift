//
//  ModelStudioView.swift
//  Magic Camera
//
//  The standalone Model Studio screen: a SceneKit stage on top, and a panel
//  with two tabs below — Assistant (the Studio chat, prompt-driven building
//  and editing) and Tools (manual primitives, nudge/rotate/scale, colours,
//  refinements). Scans import from the gallery; the result saves back to it
//  or hands off to the Spatial Scan viewer for AR and exports.
//

import SwiftUI
import simd

private enum StudioPanelTab: String, CaseIterable, Identifiable {
    case assistant = "Assistant"
    case tools = "Tools"
    var id: String { rawValue }
}

struct ModelStudioView: View {
    @State private var viewModel = ModelStudioViewModel()
    @State private var tab: StudioPanelTab = .assistant
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var showImport = false
    @State private var showSavePrompt = false
    @State private var saveName = ""
    @State private var showProjects = false
    @State private var showProjectSavePrompt = false
    @State private var projectName = ""

    var body: some View {
        @Bindable var vm = viewModel
        ZStack {
            ModelStudioRenderer(objects: viewModel.objects,
                                dragEnabled: !viewModel.isProcessing && !viewModel.isChatBusy,
                                onDragCommit: { id, offset in
                                    viewModel.commitDrag(id: id, offset: offset)
                                },
                                selectedID: $vm.selectedID,
                                frameRequest: $vm.frameRequest)
                .ignoresSafeArea(edges: .bottom)

            VStack {
                statusRow
                Spacer()
                panel
            }
            .padding(.vertical, 10)

            toastOverlay
        }
        .background(Theme.background)
        .navigationTitle("Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "folder") }
                    .accessibilityLabel("Import a saved scan")
                Menu {
                    Section("Project") {
                        Button {
                            projectName = ""
                            showProjectSavePrompt = true
                        } label: {
                            Label("Save project…", systemImage: "tray.and.arrow.down")
                        }
                        .disabled(viewModel.objects.isEmpty)
                        Button { showProjects = true } label: {
                            Label("Open project…", systemImage: "tray.full")
                        }
                    }
                    Section("Result") {
                        Button {
                            saveName = ""
                            showSavePrompt = true
                        } label: {
                            Label("Save to gallery", systemImage: "square.and.arrow.down")
                        }
                        .disabled(viewModel.objects.isEmpty)
                        Button {
                            viewModel.openInSpatialScan()
                        } label: {
                            Label("Open in Spatial Scan", systemImage: "cube.transparent")
                        }
                        .disabled(viewModel.objects.isEmpty)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(viewModel.isProcessing)
                .accessibilityLabel("Save, open or hand off")
            }
        }
        .sheet(isPresented: $showImport) {
            ScanGalleryView(onSelectCloud: { _ in },
                            onSelectMesh: { mesh, _ in
                                viewModel.importMesh(mesh, named: "Scan")
                            },
                            mergeKind: .mesh)
        }
        .alert("Save to gallery", isPresented: $showSavePrompt) {
            TextField("Model name", text: $saveName)
            Button("Save") { viewModel.saveScene(named: saveName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stage is merged into one mesh; object colours are baked into a texture.")
        }
        .alert("Save project", isPresented: $showProjectSavePrompt) {
            TextField("Project name", text: $projectName)
            Button("Save") { viewModel.saveStage(named: projectName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every object stays editable — reopen the project to continue working.")
        }
        .sheet(isPresented: $showProjects) {
            StageProjectsSheet { url in
                viewModel.loadStage(from: url)
            }
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusBadge(text: "\(viewModel.objects.count) objects · \(MeasurementFormat.count(viewModel.totalTriangles)) tris",
                        systemImage: "square.stack.3d.up", tint: Theme.accent)
            if let selected = viewModel.selectedObject {
                StatusBadge(text: selected.name, systemImage: "scope", tint: Theme.accentWarm)
            }
            Spacer()
            if viewModel.isProcessing {
                ProgressView().controlSize(.small).tint(Theme.textPrimary)
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Model Studio", systemImage: "sparkles")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if viewModel.canUndo {
                    Button { Haptics.impact(.light); viewModel.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surface, in: Capsule())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isProcessing || viewModel.isChatBusy)
                }
                Button { Haptics.impact(.light); viewModel.frameRequest = true } label: {
                    Image(systemName: "viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .padding(7)
                        .background(Theme.surface, in: Circle())
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Frame the stage")
            }
            .padding(.horizontal, 16)

            Picker("Panel", selection: $tab) {
                ForEach(StudioPanelTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if tab == .assistant { assistantPanel } else { toolsPanel }
        }
        .padding(.vertical, 14)
        .glassPanel()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Assistant tab

    @ViewBuilder
    private var assistantPanel: some View {
        if ModelStudioEngine.isAvailable {
            if viewModel.transcript.isEmpty {
                Text("Describe what to build or change — e.g. “build a snowman” or “make the box red and twice as big”.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else {
                transcriptView
            }

            if viewModel.isChatBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.textPrimary)
                    Text(viewModel.isProcessing ? "Running tools…" : "Thinking…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            HStack(spacing: 8) {
                TextField("e.g. build a small table with four legs",
                          text: $input, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.subheadline)
                    .focused($inputFocused)
                    .onSubmit(sendCommand)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium))
                    .foregroundStyle(Theme.textPrimary)
                Button(action: sendCommand) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send to Studio")
            }
            .padding(.horizontal, 16)
        } else {
            Text(ModelStudioEngine.unavailableMessage)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isChatBusy && !viewModel.isProcessing
    }

    private func sendCommand() {
        guard canSend else { return }
        Haptics.impact(.light)
        viewModel.runChatCommand(input)
        input = ""
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(viewModel.transcript) { line in
                        HStack {
                            if line.role == .user { Spacer(minLength: 40) }
                            Text(line.text)
                                .font(.footnote)
                                .foregroundStyle(line.role == .user ? AnyShapeStyle(Color.black)
                                                                    : AnyShapeStyle(Theme.textPrimary))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(line.role == .user ? AnyShapeStyle(Theme.accent)
                                                               : AnyShapeStyle(Theme.surface),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .textSelection(.enabled)
                            if line.role == .assistant { Spacer(minLength: 40) }
                        }
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 200)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: viewModel.transcript) { _, lines in
                guard let last = lines.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: - Tools tab

    private var toolsDisabled: Bool { viewModel.isProcessing || viewModel.isChatBusy }

    @ViewBuilder
    private var toolsPanel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(PrimitiveShape.allCases) { shape in
                        Button {
                            Haptics.impact(.light)
                            viewModel.addPrimitive(shape)
                        } label: {
                            Label(shape.displayName, systemImage: shape.systemImage)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Theme.surface, in: Capsule())
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .disabled(toolsDisabled)

            if viewModel.selectedObject != nil {
                selectionTools
            } else {
                Text("Add a shape or import a scan — tap an object to edit it, drag it to move it.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private var selectionTools: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                nudgeControl("X", axis: SIMD3<Float>(1, 0, 0))
                nudgeControl("Y", axis: SIMD3<Float>(0, 1, 0))
                nudgeControl("Z", axis: SIMD3<Float>(0, 0, 1))
            }

            HStack(spacing: 8) {
                toolButton("−15°", icon: "arrow.counterclockwise") {
                    viewModel.rotateObject(nil, degreesY: -15)
                }
                toolButton("+15°", icon: "arrow.clockwise") {
                    viewModel.rotateObject(nil, degreesY: 15)
                }
                toolButton("Smaller", icon: "minus.magnifyingglass") {
                    viewModel.scaleObject(nil, factor: 1 / 1.1)
                }
                toolButton("Bigger", icon: "plus.magnifyingglass") {
                    viewModel.scaleObject(nil, factor: 1.1)
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(StudioPalette.colors, id: \.name) { entry in
                        Button {
                            Haptics.impact(.light)
                            viewModel.recolorObject(nil, colorName: entry.name)
                        } label: {
                            Circle()
                                .fill(Color(red: Double(entry.value.x),
                                            green: Double(entry.value.y),
                                            blue: Double(entry.value.z)))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(
                                    viewModel.selectedObject?.colorName == entry.name
                                        ? Theme.accent : Theme.surfaceStroke,
                                    lineWidth: viewModel.selectedObject?.colorName == entry.name ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(entry.name)")
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 8) {
                toolButton("Duplicate", icon: "plus.square.on.square") {
                    viewModel.duplicateObject(nil)
                }
                asyncToolButton("Smooth", icon: "wand.and.stars") {
                    _ = await viewModel.smoothObject(nil)
                }
                asyncToolButton("Reduce", icon: "arrow.down.right.and.arrow.up.left") {
                    _ = await viewModel.reduceObject(nil)
                }
                toolButton("Delete", icon: "trash", role: .destructive) {
                    viewModel.deleteObject(nil)
                }
            }

            if viewModel.objects.count > 1 {
                HStack(spacing: 8) {
                    combineMenu
                    toolButton("Merge all", icon: "square.stack.3d.down.right") {
                        viewModel.mergeAll()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .disabled(toolsDisabled)
    }

    /// Boolean combine of the selection with any other object — union joins,
    /// subtract carves, intersect keeps the overlap.
    private var combineMenu: some View {
        Menu {
            ForEach(viewModel.objects.filter { $0.id != viewModel.selectedID }) { other in
                Menu(other.name) {
                    Button {
                        runCombine(with: other.name, operation: .union)
                    } label: {
                        Label("Union — join them", systemImage: "plus.circle")
                    }
                    Button {
                        runCombine(with: other.name, operation: .subtract)
                    } label: {
                        Label("Subtract — carve it out", systemImage: "minus.circle")
                    }
                    Button {
                        runCombine(with: other.name, operation: .intersect)
                    } label: {
                        Label("Intersect — keep the overlap", systemImage: "circle.lefthalf.filled")
                    }
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "circle.badge.minus").font(.subheadline)
                Text("Combine").font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private func runCombine(with otherName: String, operation: MeshBoolean.Operation) {
        Haptics.impact(.light)
        Task { _ = await viewModel.combineObjects(nil, with: otherName, operation: operation) }
    }

    /// −/+ nudge pair for one axis (5 cm steps).
    private func nudgeControl(_ label: String, axis: SIMD3<Float>) -> some View {
        HStack(spacing: 6) {
            Button {
                Haptics.impact(.light)
                viewModel.moveObject(nil, by: axis * -0.05)
            } label: {
                Image(systemName: "minus")
                    .font(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(Theme.surface, in: Circle())
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Button {
                Haptics.impact(.light)
                viewModel.moveObject(nil, by: axis * 0.05)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(Theme.surface, in: Circle())
                    .foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Theme.surface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }

    private func toolButton(_ title: String, icon: String,
                            role: ButtonRole? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(role: role) {
            Haptics.impact(.light)
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .foregroundStyle(role == .destructive ? Color.red : Theme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private func asyncToolButton(_ title: String, icon: String,
                                 action: @escaping () async -> Void) -> some View {
        toolButton(title, icon: icon) {
            Task { await action() }
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = viewModel.toast {
            VStack {
                ToastView(message: toast).padding(.top, 60)
                Spacer()
            }
            .animation(.spring(duration: 0.3), value: viewModel.toast)
        }
    }
}

/// Picker over the saved .mcstage projects: open one, or swipe to delete.
private struct StageProjectsSheet: View {
    let onSelect: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stages: [SavedStage] = []

    var body: some View {
        NavigationStack {
            Group {
                if stages.isEmpty {
                    ContentUnavailableView(
                        "No saved projects",
                        systemImage: "tray",
                        description: Text("Save the stage as a project to come back to it later."))
                } else {
                    List {
                        ForEach(stages) { stage in
                            Button {
                                onSelect(stage.url)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stage.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text("\(stage.objectCount) objects · \(stage.date.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets { StageStore.delete(stages[offset].url) }
                            stages.remove(atOffsets: offsets)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Studio projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { stages = StageStore.list() }
    }
}
