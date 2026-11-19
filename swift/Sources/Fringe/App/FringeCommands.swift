import AppKit
import SwiftUI

struct FringeCommands: Commands {
    let model: AppState

    var body: some Commands {
        // The scene and export items take the place of New, so the File menu does not
        // open with the separator an emptied group leaves behind.
        CommandGroup(replacing: .newItem) {
            FileMenuItems(model: model)
        }

        CommandGroup(after: .pasteboard) {
            EditMenuItems(model: model)
        }

        CommandGroup(after: .toolbar) {
            ViewMenuItems(model: model)
        }

        CommandMenu("Simulation") {
            SimulationMenuItems(model: model)
        }

        CommandMenu("Display") {
            DisplayMenuItems(model: model)
        }

        // Always in the menu bar, so it keeps its shape; its items are disabled outside a puzzle.
        CommandMenu("Puzzle") {
            PuzzleMenuItems(model: model)
        }
    }
}

/// Check, hints, Reset, moving between puzzles and switching inputs (puzzle mode).
private struct PuzzleMenuItems: View {
    let model: AppState

    var body: some View {
        let inPuzzle = model.isInPuzzle
        let puzzles = model.puzzles
        // ⌘R is Run Final in the simulator and Check in puzzle mode: one owner at a time.
        Button("Check") { model.checkPuzzle() }
            .keyboardShortcut(model.mode == .puzzles ? KeyboardShortcut("r") : nil)
            .disabled(!inPuzzle || puzzles.isChecking)
        Button("Show Hint") { puzzles.showHint() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!inPuzzle || puzzles.hintsShown >= (puzzles.session?.puzzle.hints.count ?? 0))
        Button("Reset…") { puzzles.isResetConfirmationPresented = true }
            .disabled(!inPuzzle)

        Divider()

        Button("All Puzzles") { model.closePuzzle() }
            .keyboardShortcut("[")
            .disabled(!inPuzzle)
        let id = puzzles.session?.id ?? ""
        Button("Previous Puzzle") { model.openNeighbourPuzzle(-1) }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(!inPuzzle || puzzles.neighbour(of: id, by: -1) == nil)
        Button("Next Puzzle") { model.openNeighbourPuzzle(1) }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(!inPuzzle || puzzles.neighbour(of: id, by: 1) == nil)

        // ⌃⌥ digits: free in the existing set (⌃ digits are the quantities, ⌥⌘ the
        // colormaps, ⌃⌥⌘ the solvers).
        let inputs = puzzles.session?.puzzle.inputs ?? []
        let bits = model.puzzleInputBits
        // Only the open puzzle's inputs: no disabled Input C and D in a two-input puzzle.
        if inPuzzle, !inputs.isEmpty {
            Divider()
        }
        ForEach(0..<(inPuzzle ? min(4, inputs.count) : 0), id: \.self) { i in
            let letter = String(UnicodeScalar(UInt8(65 + i)))
            Toggle("Input \(letter)", isOn: Binding(
                get: { bits.indices.contains(i) && bits[i] },
                set: { model.setPuzzleInput(i, on: $0) }
            ))
            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.control, .option])
            .disabled(!inPuzzle || i >= inputs.count)
        }
    }
}

private struct FileMenuItems: View {
    let model: AppState

    var body: some View {
        // Scenes are the simulator's: puzzle mode neither opens nor saves them, and its
        // images are not for export.
        let simulator = model.mode == .simulator
        Button("Open Scene…") { model.isSceneImporterPresented = true }
            .keyboardShortcut("o")
            .disabled(!simulator)
        Button("Save Scene…") { model.isSceneExporterPresented = true }
            .keyboardShortcut("s")
            .disabled(!simulator)
        Menu("Templates") {
            ForEach(model.examples, id: \.name) { example in
                Button(example.menuTitle) { model.loadExample(example) }
            }
        }
        .disabled(!simulator)

        Divider()

        Button("Export Image…") { model.requestExportImage() }
            .keyboardShortcut("e")
            .disabled(!simulator || model.solver.shown == nil)
        Button("Export Again") { model.exportAgain() }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(!simulator || model.lastExportURL?.pathExtension.lowercased() != "png")
        Button("Export Field Data (.npz)…") { model.exportFieldData() }
            .disabled(!simulator || model.solver.shown == nil)
        Button("Export Animation Frames…") { model.exportAnimationFrames() }
            .disabled(!simulator || model.solver.shown == nil)
        Button("Show Last Export in Finder") {
            if let url = model.lastExportURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .disabled(model.lastExportURL == nil)
    }
}

private struct EditMenuItems: View {
    let model: AppState

    var body: some View {
        Divider()
        Button("Copy Image") { model.copyImage() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.isPuzzleBrowser || model.solver.shown == nil)
        let noun = model.selectedItem?.noun ?? "Item"
        Button("Duplicate \(noun)") { model.duplicateSelectedItem() }
            .keyboardShortcut("d")
            .disabled(!(model.selectedItem.map(model.canDuplicate) ?? false))
        // No ⌘⌫ here: menu shortcuts win over text fields, so it would delete the item
        // while the user is deleting text in the inspector. Plain ⌫ in the sidebar works.
        Button("Delete \(noun)") { model.deleteSelectedItem() }
            .disabled(!(model.selectedItem.map(model.isPlayerItem) ?? false))
    }
}

private struct ViewMenuItems: View {
    let model: AppState

    private var customAspectTitle: String {
        model.output.aspect.isCustom ? "Custom (\(model.output.aspect.title))…" : "Custom…"
    }

    var body: some View {
        // ⌘1 / ⌘2: free in the existing set (⌃⌘, ⌥⌘ and ⌃⌥⌘ digits are taken).
        Toggle("Simulator", isOn: Binding(get: { model.mode == .simulator }, set: { if $0 { model.setMode(.simulator) } }))
            .keyboardShortcut("1")
        Toggle("Puzzles", isOn: Binding(get: { model.mode == .puzzles }, set: { if $0 { model.setMode(.puzzles) } }))
            .keyboardShortcut("2")

        Divider()

        // A puzzle's domain is fixed: it is part of the score.
        let simulator = model.mode == .simulator
        Button("Zoom In") { model.zoom(by: AppState.zoomStep) }
            .keyboardShortcut("=")
            .disabled(!simulator)
        Button("Zoom Out") { model.zoom(by: 1 / AppState.zoomStep) }
            .keyboardShortcut("-")
            .disabled(!simulator)
        Button("Fit Domain to Elements") { model.fitDomainToElements() }
            .keyboardShortcut("0")
            .disabled(!simulator)

        Divider()

        Menu("Aspect Ratio") {
            ForEach(OutputAspect.presets, id: \.self) { aspect in
                Toggle(aspect.title, isOn: Binding(
                    get: { model.output.aspect == aspect },
                    set: { if $0 { model.setAspect(aspect) } }
                ))
                .keyboardShortcut(KeyEquivalent(aspect.shortcutDigit ?? "0"), modifiers: [.control, .command])
            }
            Divider()
            Toggle(customAspectTitle, isOn: Binding(
                get: { model.output.aspect.isCustom },
                set: { _ in
                    model.setAspect(model.output.aspect.asCustom)
                    model.selection = .output
                    model.isInspectorPresented = true
                }
            ))
        }
        .disabled(!simulator)

        Menu("Overlays") {
            OverlayToggles(model: model, showsShortcut: true)
        }

        Divider()

        Button(model.isResultsPresented ? "Hide Results" : "Show Results") { model.toggleResults() }
            .keyboardShortcut("r", modifiers: [.command, .option])
    }
}

private struct SimulationMenuItems: View {
    let model: AppState

    var body: some View {
        // ⌘R is Check in puzzle mode (Puzzle menu).
        Button("Run Final") { model.runFinal() }
            .keyboardShortcut(model.mode == .simulator ? KeyboardShortcut("r") : nil)
            .disabled(model.mode != .simulator || !model.solver.canRunFinal)
        Button("Cancel") {
            if model.puzzles.isChecking { model.cancelPuzzleCheck() } else { model.cancelSolve() }
        }
        .keyboardShortcut(".")
        .disabled(!model.solver.isRunning && !model.puzzles.isChecking)

        Divider()

        Menu("Solver") {
            ForEach(Array(SolverMethod.allCases.enumerated()), id: \.element) { index, method in
                Toggle(method.title, isOn: Binding(
                    get: { model.scene.solver.method == method },
                    set: { if $0 { model.setMethod(method) } }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .option, .command])
            }
        }
        .disabled(model.mode != .simulator)

        Divider()

        // In a puzzle, parts come from the palette in the sidebar (the Puzzle menu has no
        // other way to add one).
        Menu("Add") {
            AddItemSections(model: model)
        }
        .disabled(model.mode != .simulator)
        let selected = model.selectedItem
        let noun = selected?.noun ?? "Item"
        Button(selected.map { model.isEnabled($0) } == false ? "Enable \(noun)" : "Disable \(noun)") {
            model.toggleSelectedItemEnabled()
        }
        // ⇧⌘D: ⌥⌘D belongs to the system (Dock hiding) and never reaches the app.
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(!(selected.map(model.isPlayerItem) ?? false))
    }
}

private struct DisplayMenuItems: View {
    let model: AppState

    var body: some View {
        ForEach(Quantity.allCases) { quantity in
            Toggle(quantity.title, isOn: Binding(
                get: { model.display.quantity == quantity },
                set: { if $0 { model.setQuantity(quantity) } }
            ))
            .keyboardShortcut(KeyEquivalent(quantity.shortcutDigit), modifiers: [.control])
        }

        Divider()

        Menu("Field Part") {
            ForEach(FieldPartName.allCases) { part in
                Toggle(part.title, isOn: Binding(
                    get: { model.display.part == part },
                    set: { if $0 { model.edit("Change Field Part") { $0.display.part = part } } }
                ))
            }
        }

        Menu("Colormap") {
            // Toggles rather than an inline picker, which would open the menu with a separator.
            ForEach(Array(model.availableColormaps.enumerated()), id: \.element) { index, colormap in
                Toggle(colormap.title, isOn: Binding(
                    get: { model.display.colormap == colormap },
                    set: { if $0 { model.setColormap(colormap) } }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }

            Divider()

            Button("Next Colormap") { model.nextColormap() }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Colormap") { model.previousColormap() }
                .keyboardShortcut("[", modifiers: [.command, .option])
        }

        Divider()

        Button(model.display.isPlaying ? "Pause Phase" : "Play Phase") { model.togglePlaying() }
            .keyboardShortcut("p", modifiers: [.command, .option])
        // ⌥⌘ rather than ⌥ alone: menu shortcuts win over text fields, and ⌥← / ⌥→ must
        // keep moving by word in the inspector.
        Button("Step Phase Forward") { model.stepPhase(by: 15) }
            .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
        Button("Step Phase Back") { model.stepPhase(by: -15) }
            .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
    }
}
