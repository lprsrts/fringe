import SwiftUI

struct MainToolbar: CustomizableToolbarContent {
    let model: AppState

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "mode", placement: .navigation) {
            ModePicker(model: model)
        }

        if model.mode == .simulator {
            SimulatorToolbarItems(model: model)
        }

        if model.isPuzzleBrowser {
            ToolbarSpacer(.flexible)
            ToolbarItem(id: "puzzle.tally") {
                let puzzles = model.puzzles
                PuzzleTally(solved: puzzles.solvedCount(), total: puzzles.catalog.count,
                            stars: puzzles.starCount(), maxStars: puzzles.maxStars())
                    .padding(.horizontal, 8)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        if model.isInPuzzle {
            PuzzleToolbarItems(model: model)
        }
    }
}

/// Simulator or Puzzles (⌘1, ⌘2), at the leading edge in every mode.
struct ModePicker: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("ModePicker")
        Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
            Text("Simulator").tag(AppMode.simulator)
            Text("Puzzles").tag(AppMode.puzzles)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch between the simulator (⌘1) and the puzzles (⌘2)")
    }
}

/// The simulator's own toolbar items; puzzle mode shows its own instead, under other ids so
/// toolbar customisation never mixes the two. Each item's content is a view of its own that
/// reads the document itself: read here, a document change (every committed drag step)
/// re-evaluated this content and made SwiftUI rebuild every toolbar item.
struct SimulatorToolbarItems: CustomizableToolbarContent {
    let model: AppState

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "add") {
            AddElementMenu(model: model)
                .help("Add a source, element or detector")
        }

        ToolbarItem(id: "solver") {
            SolverMenu(model: model)
        }

        ToolbarItem(id: "run") {
            RunFinalControl(model: model)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)

        ToolbarItem(id: "quantity") {
            QuantityMenu(model: model)
        }

        ToolbarItem(id: "play") {
            PlayButton(model: model)
        }

        // One menu for the overlays and the colormap, so the toolbar fits the narrowest window.
        ToolbarItem(id: "look") {
            LookMenu(model: model)
        }

        // Output and zoom are in the sidebar, the View menu and on the canvas; they start
        // hidden so the toolbar fits the narrowest window, and Customize Toolbar adds them.
        ToolbarItem(id: "output") {
            OutputFormatMenu(model: model)
                .help("Output format")
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "zoom") {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoom(by: 1 / AppState.zoomStep) }
                    .help("Zoom out (⌘−)")
                Button("Fit Domain to Elements", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.fitDomainToElements() }
                    .help("Fit the domain to the elements (⌘0)")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoom(by: AppState.zoomStep) }
                    .help("Zoom in (⌘=)")
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
            }
        }
        .defaultCustomization(.hidden)

        if model.isExporting {
            ToolbarItem(id: "progress") {
                ProgressView()
                    .controlSize(.small)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(id: "export") {
            ExportButton(model: model)
        }

        // While the inspector shows, its toggle sits in the inspector's own toolbar section.
        if !model.isInspectorPresented {
            ToolbarItem(id: "inspector") {
                InspectorToggle(model: model)
            }
        }
    }
}

private struct SolverMenu: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("SolverMenu")
        // A menu with an explicit label, as for the quantity: it keeps the toolbar short
        // enough for the narrowest window.
        Menu {
            Picker("Solver", selection: Binding(get: { model.toolbarDocument.method }, set: { model.setMethod($0) })) {
                ForEach(SolverMethod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(model.toolbarDocument.method.title)
        }
        .help("Solver (⌃⌥⌘1–3)")
    }
}

private struct QuantityMenu: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("QuantityMenu")
        // A menu with an explicit label: a menu-style picker in the toolbar shows only the
        // icon and leaves the title blank.
        Menu {
            Picker("Quantity", selection: Binding(get: { model.toolbarDocument.display.quantity }, set: { model.setQuantity($0) })) {
                ForEach(Quantity.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(model.toolbarDocument.display.quantity.title)
        }
        .help("Quantity (⌃1–⌃4)")
    }
}

private struct PlayButton: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("PlayButton")
        Button(model.toolbarDocument.isPlaying ? "Pause" : "Play", systemImage: model.toolbarDocument.isPlaying ? "pause.fill" : "play.fill") {
            model.togglePlaying()
        }
        .help(model.toolbarDocument.isPlaying ? "Pause the phase animation (⌥⌘P)" : "Animate the phase (⌥⌘P)")
    }
}

private struct LookMenu: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("LookMenu")
        Menu {
            OverlayToggles(model: model)
            Divider()
            Picker("Colormap", selection: Binding(get: { model.toolbarDocument.display.colormap }, set: { model.setColormap($0) })) {
                ForEach(ColormapName.all(of: model.toolbarDocument.display.quantity.colormapKind)) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
        } label: {
            Label("Overlays and Colormap", systemImage: "square.3.layers.3d")
        }
        .help("Overlays (⇧⌘O shows or hides all) and colormap: \(model.toolbarDocument.display.colormap.title) (⌥⌘[ / ⌥⌘])")
    }
}

private struct ExportButton: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("ExportButton")
        Button("Export…", systemImage: "square.and.arrow.up") { model.requestExportImage() }
            .labelStyle(.iconOnly)
            .disabled(!model.hasShownResult)
            .help("Export PNG (⌘E)")
    }
}

struct InspectorToggle: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("InspectorToggle")
        Button("Inspector", systemImage: "sidebar.trailing") {
            model.isInspectorPresented.toggle()
        }
        .help("Show or hide the inspector (⌃⌘I)")
    }
}

/// Run Final, which turns into a progress ring and a stop button while a solve runs.
struct RunFinalControl: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("RunFinalControl")
        let solver = model.solver
        // Not while a drag runs its previews (one or two a second, each a few hundred
        // milliseconds): every swap between the button and the ring rebuilt all toolbar
        // items, which stalled the drag. The canvas shows each preview's progress, and ⌘.
        // still stops it.
        if solver.isRunning, !model.isTracking {
            HStack(spacing: 6) {
                ProgressView(value: min(1, max(0, solver.progress.fraction)))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Button("Stop", systemImage: "stop.fill") { model.cancelSolve() }
                    .labelStyle(.iconOnly)
            }
            .help("\(solver.progressDescription). Stop with ⌘.")
        } else {
            // The main compute action: labelled and prominent, as Check is in a puzzle, and
            // with a glyph that does not read as the phase animation's play.
            Button("Run Final", systemImage: "bolt.fill") { model.runFinal() }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glassProminent)
                .disabled(!solver.canRunFinal)
                .help(runHelp)
        }
    }

    private var runHelp: String {
        // The estimate changes with every committed drag step; a new tooltip would rebuild
        // the toolbar each time, so a drag shows the plain one.
        if model.isTracking { return "Solve at final quality (⌘R)" }
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
        let _ = PerfProbe.body("AddElementMenu")
        Menu("Add", systemImage: "plus") {
            AddItemSections(model: model)
        }
    }
}

/// Sources, refractive and opaque elements, and detectors, for the toolbar's and the
/// Simulation menu's add menus.
struct AddItemSections: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("AddItemSections")
        Section("Sources") {
            AddSourceItems(model: model)
        }
        AddElementItems(model: model)
        Section("Detectors") {
            AddDetectorItems(model: model)
        }
    }
}

/// The element kinds, grouped as refractive and opaque.
struct AddElementItems: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("AddElementItems")
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
        let _ = PerfProbe.body("OutputFormatMenu")
        Menu {
            Picker("Aspect Ratio", selection: Binding(get: { model.toolbarDocument.output.aspect }, set: { model.binding("Change Aspect Ratio", \.output.aspect).wrappedValue = $0 })) {
                ForEach(OutputAspect.presets, id: \.self) { Text($0.title).tag($0) }
                if model.toolbarDocument.output.aspect.isCustom {
                    Text(model.toolbarDocument.output.aspect.title).tag(model.toolbarDocument.output.aspect)
                }
            }
            .pickerStyle(.inline)

            Picker("Size", selection: Binding(get: { model.toolbarDocument.output.longEdge }, set: { model.binding("Change Size", \.output.longEdge).wrappedValue = $0 })) {
                ForEach(LongEdge.presets, id: \.self) { Text("\($0.pixels) px").tag($0) }
                if model.toolbarDocument.output.longEdge.isCustom {
                    Text("\(model.toolbarDocument.output.longEdge.pixels) px").tag(model.toolbarDocument.output.longEdge)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("Custom Ratio…") {
                if !model.toolbarDocument.output.aspect.isCustom {
                    model.setAspect(model.toolbarDocument.output.aspect.asCustom)
                }
                model.selection = .output
                model.isInspectorPresented = true
            }

            Button("Custom Size…") {
                model.selection = .output
                model.isInspectorPresented = true
            }
        } label: {
            Label(model.toolbarDocument.output.aspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
    }
}
