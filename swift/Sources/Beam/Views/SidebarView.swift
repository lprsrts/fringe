import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var model

    var body: some View {
        List(selection: selection) {
            Section("Beam") {
                BeamRow(beam: model.beam)
                    .tag(SidebarItem.beam)
            }

            Section("Optics") {
                if model.elements.isEmpty {
                    Text("No elements")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(model.elements) { element in
                        ElementRow(element: element)
                            .tag(SidebarItem.element(element.id))
                            .contextMenu { ElementContextMenu(model: model, id: element.id) }
                    }
                }
            }

            Section("Image") {
                Label("Appearance", systemImage: "paintpalette")
                    .tag(SidebarItem.appearance)
                Label("Output", systemImage: "aspectratio")
                    .badge(Text(model.outputSummary).monospacedDigit())
                    .tag(SidebarItem.output)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: model.selectedElementID == nil ? nil : { model.deleteSelectedElement() })
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.selection },
            set: { if let item = $0 { model.selection = item } }
        )
    }
}

private struct BeamRow: View {
    let beam: BeamParameters

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("Gaussian Beam")
                Text("\(Format.wavelength(beam.wavelength)) · w₀ \(Format.millimetres(beam.w0, digits: 3))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: "light.beacon.max")
        }
    }
}

private struct ElementRow: View {
    let element: PlacedElementModel

    var body: some View {
        Label(element.name, systemImage: element.type.symbol)
            .badge(Text(Format.centimetres(element.z)).monospacedDigit())
            .foregroundStyle(element.isEnabled ? .primary : .secondary)
    }
}

struct ElementContextMenu: View {
    let model: AppState
    let id: UUID

    var body: some View {
        let isEnabled = model.scene[element: id]?.isEnabled ?? true
        Button(isEnabled ? "Disable Element" : "Enable Element") {
            model.edit(isEnabled ? "Disable Element" : "Enable Element") {
                $0[element: id]?.isEnabled.toggle()
            }
        }
        Button("Duplicate Element") {
            model.selection = .element(id)
            model.duplicateSelectedElement()
        }
        Divider()
        Button("Delete Element", role: .destructive) {
            model.selection = .element(id)
            model.deleteSelectedElement()
        }
    }
}
