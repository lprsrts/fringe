import AppKit
import SwiftUI

struct BeamCommands: Commands {
    let model: AppState

    var body: some Commands {
        // Export takes the place of New rather than of the import/export group, so the
        // File menu does not open with the separator an emptied group leaves behind.
        CommandGroup(replacing: .newItem) {
            ExportMenuItems(model: model)
        }

        CommandGroup(after: .pasteboard) {
            EditMenuItems(model: model)
        }

        CommandGroup(after: .toolbar) {
            ViewMenuItems(model: model)
        }

        CommandMenu("Optics") {
            OpticsMenuItems(model: model)
        }

        // There is no help book, so the default item would only show "Help isn't available".
        CommandGroup(replacing: .help) {}
    }
}

private struct ExportMenuItems: View {
    let model: AppState

    var body: some View {
        Button("Export…") { model.isExporterPresented = true }
            .keyboardShortcut("e")
        Button("Export Again") { model.exportAgain() }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(model.lastExportURL == nil)
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

    var body: some View {
        Button("Zoom In") { model.zoom(by: 1.25) }
            .keyboardShortcut("=")
        Button("Zoom Out") { model.zoom(by: 0.8) }
            .keyboardShortcut("-")
        Button("Zoom to Fit") { model.zoomToFit() }
            .keyboardShortcut("0")

        Divider()

        Menu("Aspect Ratio") {
            ForEach(OutputAspect.allCases) { aspect in
                Toggle(aspect.title, isOn: Binding(
                    get: { model.output.aspect == aspect },
                    set: { if $0 { model.setAspect(aspect) } }
                ))
                .keyboardShortcut(KeyEquivalent(aspect.shortcutDigit), modifiers: [.control, .command])
            }
        }

        Menu("Overlays") {
            OverlayToggles(model: model, showsShortcut: true)
        }

        Menu("Colormap") {
            // Toggles rather than an inline picker, which would open the menu with a separator.
            ForEach(ColormapOption.allCases) { colormap in
                Toggle(colormap.displayName, isOn: Binding(
                    get: { model.style.colormap == colormap },
                    set: { if $0 { model.setColormap(colormap) } }
                ))
            }

            Divider()

            Button("Next Colormap") { model.nextColormap() }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Colormap") { model.previousColormap() }
                .keyboardShortcut("[", modifiers: [.command, .option])
        }
    }
}

private struct OpticsMenuItems: View {
    let model: AppState

    var body: some View {
        ForEach(Array(OpticalElementType.allCases.enumerated()), id: \.element) { index, type in
            Button("Add \(type.displayName)") { model.addElement(type) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
        }

        Divider()

        Button(model.selectedElement?.isEnabled == false ? "Enable Element" : "Disable Element") {
            model.toggleSelectedElementEnabled()
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
        .disabled(model.selectedElementID == nil)
    }
}

/// "Show Overlays" and the six overlay toggles, shared by the View menu, the toolbar and
/// the inspector. Menu items are title case; the inspector's checkboxes are sentence case.
struct OverlayToggles: View {
    let model: AppState
    var inMenu = true
    var showsShortcut = false

    var body: some View {
        Toggle(title("Show Overlays", "Show overlays"), isOn: model.binding("Show Overlays", \.style.showOverlays))
            .keyboardShortcut(showsShortcut ? KeyboardShortcut("o", modifiers: [.command, .shift]) : nil)

        if inMenu {
            Divider()
        }

        Group {
            Toggle(title("Beam Envelope", "Beam envelope"), isOn: model.binding("Change Overlays", \.style.showEnvelope))
            Toggle("Wavefronts", isOn: model.binding("Change Overlays", \.style.showWavefrontArcs))
            Toggle(title("Optical Elements", "Optical elements"), isOn: model.binding("Change Overlays", \.style.showElementGlyphs))
            Toggle(title("Rayleigh Range Markers", "Rayleigh range markers"), isOn: model.binding("Change Overlays", \.style.showRayleighMarkers))
            Toggle(title("Optical Axis", "Optical axis"), isOn: model.binding("Change Overlays", \.style.showCenterline))
            Toggle("Caption", isOn: model.binding("Change Overlays", \.style.showMetadataWatermark))
        }
        .disabled(!model.style.showOverlays)
    }

    private func title(_ menuTitle: String, _ checkboxTitle: String) -> String {
        inMenu ? menuTitle : checkboxTitle
    }
}
