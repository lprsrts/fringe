import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var model

    var body: some View {
        List(selection: selection) {
            Section("Source") {
                SourceRow(scene: model.scene)
                    .tag(SidebarItem.source)
            }

            Section("Elements") {
                if model.scene.elements.isEmpty {
                    Text("No elements")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(Array(model.scene.elements.enumerated()), id: \.element.id) { index, element in
                        ElementRow(
                            model: model,
                            element: element,
                            hasErrors: model.checkReport?.issues(forElement: index).contains(where: \.isError) ?? false
                        )
                        .tag(SidebarItem.element(element.id))
                        .contextMenu { ElementContextMenu(model: model, id: element.id) }
                    }
                }
            }

            Section("Simulation") {
                SimulationRow(model: model)
                    .tag(SidebarItem.simulation)
            }

            Section("Image") {
                Label("Display", systemImage: "paintpalette")
                    .badge(Text(model.display.quantity.symbol))
                    .tag(SidebarItem.display)
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

private struct SourceRow: View {
    let scene: SimScene

    var body: some View {
        let source = scene.source
        let lambda = "λ \(Format.number(scene.wavelengthUm, digits: 2...2)) µm"
        let summary = source.kind == .gaussianBeam
            ? "Gaussian · \(lambda) · w₀ \(Format.number(source.waistUm, digits: 1...1)) µm"
            : "Plane wave · \(lambda) · \(Format.degrees(source.angleDeg, digits: 0))"
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary)
                Text("Background n \(Format.number(scene.background.n, digits: 3...3))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        } icon: {
            Image(systemName: source.kind == .gaussianBeam ? "light.beacon.max" : "water.waves")
        }
    }
}

private struct ElementRow: View {
    let model: AppState
    let element: Element
    let hasErrors: Bool

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(element.displayName)
                    .foregroundStyle(element.enabled ? .primary : .secondary)
            } icon: {
                Image(systemName: element.kind.symbol)
            }
            Spacer(minLength: 4)
            if hasErrors {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("This element has problems; select it to see them")
            }
            Text(element.material.badge)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Toggle("Enabled", isOn: Binding(
                get: { element.enabled },
                set: { _ in model.toggleEnabled(element.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(element.enabled ? "Disable this element" : "Enable this element")
            .accessibilityLabel("Enable \(element.displayName)")
        }
    }
}

private struct SimulationRow: View {
    let model: AppState

    var body: some View {
        let solver = model.scene.solver
        let status = model.solver.status
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(solver.method.title) · final \(SceneFormat.fixed(solver.ppw(final: true), 0))/λ")
                HStack(spacing: 4) {
                    if model.solver.isRunning {
                        ProgressView().controlSize(.mini)
                    }
                    Text(status.title)
                }
                .font(.subheadline)
                .foregroundStyle(status.isError ? AnyShapeStyle(.red) : (status.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)))
            }
            .monospacedDigit()
        } icon: {
            Image(systemName: "function")
        }
    }
}

struct ElementContextMenu: View {
    let model: AppState
    let id: String

    var body: some View {
        let isEnabled = model.scene[element: id]?.enabled ?? true
        Button(isEnabled ? "Disable Element" : "Enable Element") {
            model.toggleEnabled(id)
        }
        Button("Duplicate Element") {
            model.selection = .element(id)
            model.duplicateSelectedElement()
        }
        Divider()
        Button("Delete Element", role: .destructive) {
            model.deleteElement(id)
        }
    }
}
