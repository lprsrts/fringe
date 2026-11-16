import SwiftUI

struct MainToolbar: CustomizableToolbarContent {
    let model: AppState

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "add", placement: .navigation) {
            AddElementMenu(model: model)
                .help("Add an element")
        }

        ToolbarItem(id: "solver") {
            Picker("Solver", selection: Binding(get: { model.scene.solver.method }, set: { model.setMethod($0) })) {
                ForEach(SolverMethod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Solver (⌃⌥⌘1–3)")
        }

        ToolbarItem(id: "run") {
            RunFinalControl(model: model)
        }

        ToolbarSpacer(.flexible)

        ToolbarItem(id: "quantity") {
            Picker("Quantity", selection: Binding(get: { model.display.quantity }, set: { model.setQuantity($0) })) {
                ForEach(Quantity.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Quantity (⌃1–⌃4)")
        }

        ToolbarItem(id: "play") {
            Button(model.display.isPlaying ? "Pause" : "Play", systemImage: model.display.isPlaying ? "pause.fill" : "play.fill") {
                model.togglePlaying()
            }
            .help(model.display.isPlaying ? "Pause the phase animation (⌥⌘P)" : "Animate the phase (⌥⌘P)")
        }

        ToolbarItem(id: "look") {
            ControlGroup {
                Menu("Overlays", systemImage: "square.3.layers.3d") {
                    OverlayToggles(model: model)
                }
                .help("Overlays (⇧⌘O)")
                Picker("Colormap", systemImage: "paintpalette", selection: Binding(get: { model.display.colormap }, set: { model.setColormap($0) })) {
                    ForEach(model.availableColormaps) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Colormap (⌥⌘[ / ⌥⌘])")
            } label: {
                Label("Overlays and Colormap", systemImage: "square.3.layers.3d")
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "output") {
            OutputFormatMenu(model: model)
                .help("Output format")
        }

        ToolbarItem(id: "zoom") {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoom(by: 1 / AppState.zoomStep) }
                    .help("Zoom out (⌘−)")
                Button("Fit to Elements", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.fitDomainToElements() }
                    .help("Fit the domain to the elements (⌘0)")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoom(by: AppState.zoomStep) }
                    .help("Zoom in (⌘=)")
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
            }
        }

        if model.isExporting {
            ToolbarItem(id: "progress") {
                ProgressView()
                    .controlSize(.small)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "export", placement: .primaryAction) {
            Button("Export…") { model.requestExportImage() }
                .buttonStyle(.glassProminent)
                .disabled(model.solver.shown == nil)
                .help("Export PNG (⌘E)")
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "inspector") {
            Button("Inspector", systemImage: "sidebar.trailing") {
                model.isInspectorPresented.toggle()
            }
            .help("Show or hide the inspector (⌃⌘I)")
        }
    }
}

/// Run Final, which turns into a progress ring and a stop button while a solve runs.
struct RunFinalControl: View {
    let model: AppState

    var body: some View {
        let solver = model.solver
        if solver.isRunning {
            HStack(spacing: 6) {
                ProgressView(value: min(1, max(0, solver.progress.fraction)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Button("Stop", systemImage: "stop.fill") { model.cancelSolve() }
                    .labelStyle(.iconOnly)
            }
            .help("\(solver.progressDescription). Stop with ⌘.")
        } else {
            Button("Run Final", systemImage: "play.rectangle") { model.runFinal() }
                .disabled(!solver.canRunFinal)
                .help(runHelp)
        }
    }

    private var runHelp: String {
        if let tooLarge = model.solver.finalTooLarge {
            return tooLarge.sentence
        }
        if let estimate = model.checkReport?.estimates?.final {
            return "Solve at final quality (⌘R): ≈ \(estimate.summary) · \(SceneFormat.megabytes(estimate.memoryMb))"
        }
        return "Solve at final quality (⌘R)"
    }
}

struct AddElementMenu: View {
    let model: AppState

    var body: some View {
        Menu("Add Element", systemImage: "plus") {
            AddElementItems(model: model)
        }
    }
}

/// The element kinds, grouped as refractive and opaque.
struct AddElementItems: View {
    let model: AppState

    var body: some View {
        Section("Refractive") {
            ForEach(ShapeKind.refractive) { kind in
                Button(kind.title, systemImage: kind.symbol) { model.addElement(kind) }
            }
        }
        Section("Opaque") {
            ForEach(ShapeKind.opaque) { kind in
                Button(kind.title, systemImage: kind.symbol) { model.addElement(kind) }
            }
        }
    }
}

struct OutputFormatMenu: View {
    let model: AppState

    var body: some View {
        Menu {
            Picker("Aspect Ratio", selection: model.binding("Change Aspect Ratio", \.output.aspect)) {
                ForEach(OutputAspect.presets, id: \.self) { Text($0.title).tag($0) }
                if model.output.aspect.isCustom {
                    Text(model.output.aspect.title).tag(model.output.aspect)
                }
            }
            .pickerStyle(.inline)

            Picker("Size", selection: model.binding("Change Size", \.output.longEdge)) {
                ForEach(LongEdge.presets, id: \.self) { Text("\($0.pixels) px").tag($0) }
                if model.output.longEdge.isCustom {
                    Text("\(model.output.longEdge.pixels) px").tag(model.output.longEdge)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("Custom Ratio…") {
                if !model.output.aspect.isCustom {
                    model.setAspect(model.output.aspect.asCustom)
                }
                model.selection = .output
                model.isInspectorPresented = true
            }

            Button("Custom Size…") {
                model.selection = .output
                model.isInspectorPresented = true
            }
        } label: {
            Label(model.output.aspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
    }
}
