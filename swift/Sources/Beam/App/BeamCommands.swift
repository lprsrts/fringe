import AppKit
import SwiftUI

struct BeamCommands: Commands {
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

        // There is no help book, so the default item would only show "Help isn't available".
        CommandGroup(replacing: .help) {}
    }
}

private struct FileMenuItems: View {
    let model: AppState

    var body: some View {
        Button("Open Scene…") { model.isSceneImporterPresented = true }
            .keyboardShortcut("o")
        Button("Save Scene…") { model.isSceneExporterPresented = true }
            .keyboardShortcut("s")
        Menu("Templates") {
            ForEach(model.examples, id: \.name) { example in
                Button(example.menuTitle) { model.loadExample(example) }
            }
        }

        Divider()

        Button("Export Image…") { model.requestExportImage() }
            .keyboardShortcut("e")
            .disabled(model.solver.shown == nil)
        Button("Export Again") { model.exportAgain() }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(model.lastExportURL?.pathExtension.lowercased() != "png")
        Button("Export Field Data (.npy)…") { model.exportFieldData() }
            .disabled(model.solver.shown == nil)
        Button("Export Animation Frames…") { model.exportAnimationFrames() }
            .disabled(model.solver.shown == nil)
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
            .disabled(model.solver.shown == nil)
        Button("Duplicate Element") { model.duplicateSelectedElement() }
            .keyboardShortcut("d")
            .disabled(model.selectedElementID == nil)
        // No ⌘⌫ here: menu shortcuts win over text fields, so it would delete the element
        // while the user is deleting text in the inspector. Plain ⌫ in the sidebar works.
        Button("Delete Element") { model.deleteSelectedElement() }
            .disabled(model.selectedElementID == nil)
    }
}

private struct ViewMenuItems: View {
    let model: AppState

    private var customAspectTitle: String {
        model.output.aspect.isCustom ? "Custom (\(model.output.aspect.title))…" : "Custom…"
    }

    var body: some View {
        Button("Zoom In") { model.zoom(by: AppState.zoomStep) }
            .keyboardShortcut("=")
        Button("Zoom Out") { model.zoom(by: 1 / AppState.zoomStep) }
            .keyboardShortcut("-")
        Button("Fit to Elements") { model.fitDomainToElements() }
            .keyboardShortcut("0")

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

        Menu("Overlays") {
            OverlayToggles(model: model, showsShortcut: true)
        }
    }
}

private struct SimulationMenuItems: View {
    let model: AppState

    var body: some View {
        Button("Run Final") { model.runFinal() }
            .keyboardShortcut("r")
            .disabled(!model.solver.canRunFinal)
        Button("Cancel") { model.cancelSolve() }
            .keyboardShortcut(".")
            .disabled(!model.solver.isRunning)

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

        Divider()

        Menu("Add Element") {
            AddElementItems(model: model)
        }
        Button(model.selectedElement?.enabled == false ? "Enable Element" : "Disable Element") {
            model.toggleSelectedElementEnabled()
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
        .disabled(model.selectedElementID == nil)
        Button("Fit Domain to Elements") { model.fitDomainToElements() }
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
        Button("Step Phase Forward") { model.stepPhase(by: 15) }
            .keyboardShortcut(.rightArrow, modifiers: [.option])
        Button("Step Phase Back") { model.stepPhase(by: -15) }
            .keyboardShortcut(.leftArrow, modifiers: [.option])
    }
}
