import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var model

    var body: some View {
        let _ = PerfProbe.body("SidebarView")
        let scene = model.scene
        let report = model.checkReport
        List(selection: selection) {
            Section {
                IlluminationRow(scene: scene)
                    .tag(SidebarItem.illumination)
                ForEach(Array(scene.sources.enumerated()), id: \.element.id) { index, source in
                    SourceRow(
                        model: model,
                        source: source,
                        hasErrors: report?.issues(forSource: index).contains(where: \.isError) ?? false
                    )
                    .tag(SidebarItem.source(source.id))
                    .contextMenu { ItemContextMenu(model: model, item: .source(source.id)) }
                }
            } header: {
                SectionHeader(title: "Sources") {
                    AddSourceItems(model: model)
                }
                .help("Add a source")
            }

            Section {
                if scene.elements.isEmpty {
                    Text("No elements")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(Array(scene.elements.enumerated()), id: \.element.id) { index, element in
                        ElementRow(
                            model: model,
                            element: element,
                            hasErrors: report?.issues(forElement: index).contains(where: \.isError) ?? false
                        )
                        .tag(SidebarItem.element(element.id))
                        .contextMenu { ItemContextMenu(model: model, item: .element(element.id)) }
                    }
                }
            } header: {
                SectionHeader(title: "Elements") {
                    AddElementItems(model: model)
                }
                .help("Add an element")
            }

            Section {
                if scene.detectors.isEmpty {
                    Text("No detectors")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(Array(scene.detectors.enumerated()), id: \.element.id) { index, detector in
                        DetectorRow(
                            model: model,
                            detector: detector,
                            reading: model.detectorReadings[detector.id],
                            hasErrors: report?.issues(forDetector: index).contains(where: \.isError) ?? false
                        )
                        .tag(SidebarItem.detector(detector.id))
                        .contextMenu { ItemContextMenu(model: model, item: .detector(detector.id)) }
                    }
                }
            } header: {
                SectionHeader(title: "Detectors") {
                    AddDetectorItems(model: model)
                }
                .help("Add a detector")
            }

            Section("Simulation") {
                SimulationRow(model: model)
                    .tag(SidebarItem.simulation)
            }

            Section("Image") {
                Label("Display", systemImage: "paintpalette")
                    .badge(Text(MathTypesetter.styled(model.display.quantity.mathSymbol, pointSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).font(.caption))
                    .tag(SidebarItem.display)
                Label("Output", systemImage: "aspectratio")
                    .badge(Text(model.windowSubtitle).font(.caption).monospacedDigit())
                    .tag(SidebarItem.output)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: model.selectedItem == nil ? nil : { model.deleteSelectedItem() })
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: { model.selection },
            set: { if let item = $0 { model.selection = item } }
        )
    }
}

/// A section title with a borderless add menu at its trailing edge.
private struct SectionHeader<Items: View>: View {
    let title: String
    @ViewBuilder let items: () -> Items

    var body: some View {
        let _ = PerfProbe.body("SectionHeader")
        HStack {
            Text(title)
            Spacer()
            Menu {
                items()
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add to \(title)")
        }
    }
}

/// The wavelength and background medium all sources share.
private struct IlluminationRow: View {
    let scene: SimScene

    var body: some View {
        let _ = PerfProbe.body("IlluminationRow")
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("Wavelength and Medium")
                MathText(#"$\lambda$ "# + "\(Format.number(scene.wavelengthUm * 1000, digits: 0...1)) nm · $n_b$ \(Format.number(scene.background.n, digits: 3...3))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: "rainbow")
        }
    }
}

/// Badge, enable checkbox and issue mark shared by source, element and detector rows.
struct ItemRow: View {
    let model: AppState
    let item: SceneItem
    let title: String
    let symbol: String
    let enabled: Bool
    let badge: String
    let hasErrors: Bool

    var body: some View {
        let _ = PerfProbe.body("ItemRow")
        HStack(spacing: 6) {
            Label {
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(enabled ? .primary : .secondary)
            } icon: {
                Image(systemName: symbol)
            }
            Spacer(minLength: 4)
            if hasErrors {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("This \(item.noun.lowercased()) has problems; select it to see them")
                    .accessibilityLabel("Has problems")
            }
            if !badge.isEmpty {
                MathText(badge)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Toggle("Enabled", isOn: Binding(
                get: { enabled },
                set: { _ in model.toggleEnabled(item) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(enabled ? "Disable this \(item.noun.lowercased())" : "Enable this \(item.noun.lowercased())")
            .accessibilityLabel("Enable \(title)")
        }
    }
}

private struct SourceRow: View {
    let model: AppState
    let source: Source
    let hasErrors: Bool

    var body: some View {
        let _ = PerfProbe.body("SourceRow")
        ItemRow(
            model: model,
            item: .source(source.id),
            title: source.displayName,
            symbol: source.kind.symbol,
            enabled: source.enabled,
            badge: Self.badge(source),
            hasErrors: hasErrors
        )
    }

    /// "$A$ 1.00", plus the phase when it is not zero.
    static func badge(_ source: Source) -> String {
        var text = "$A$ \(Format.number(source.amplitude, digits: 2...2))"
        let phase = source.phaseDeg.truncatingRemainder(dividingBy: 360)
        if abs(phase) > 1e-9 {
            text += #"  $\varphi$ "# + Format.degrees(source.phaseDeg, digits: 0)
        }
        return text
    }
}

struct ElementRow: View {
    let model: AppState
    let element: Element
    let hasErrors: Bool

    var body: some View {
        let _ = PerfProbe.body("ElementRow")
        ItemRow(
            model: model,
            item: .element(element.id),
            title: element.displayName,
            symbol: element.kind.symbol,
            enabled: element.enabled,
            badge: element.material.badge,
            hasErrors: hasErrors
        )
    }
}

private struct DetectorRow: View {
    let model: AppState
    let detector: Detector
    let reading: DetectorReading?
    let hasErrors: Bool

    var body: some View {
        let _ = PerfProbe.body("DetectorRow")
        ItemRow(
            model: model,
            item: .detector(detector.id),
            title: detector.displayName,
            symbol: detector.kind.symbol,
            enabled: detector.enabled,
            badge: detector.enabled ? (reading.flatMap { model.readingSummary($0) } ?? "") : "",
            hasErrors: hasErrors
        )
    }
}

private struct SimulationRow: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("SimulationRow")
        let solver = model.scene.solver
        let status = model.solver.status
        Label {
            VStack(alignment: .leading, spacing: 1) {
                MathText("\(solver.method.title) · final \(Format.number(solver.ppw(final: true), digits: 0...1))/" + #"$\lambda$"#)
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

/// Enable/Disable, Duplicate and Delete for a source, element or detector.
struct ItemContextMenu: View {
    let model: AppState
    let item: SceneItem

    var body: some View {
        let _ = PerfProbe.body("ItemContextMenu")
        let noun = item.noun
        let mine = model.isPlayerItem(item)
        Button(model.isEnabled(item) ? "Disable \(noun)" : "Enable \(noun)") {
            model.toggleEnabled(item)
        }
        .disabled(!mine)
        Button("Duplicate \(noun)") {
            model.duplicate(item)
        }
        .disabled(!model.canDuplicate(item))
        Divider()
        Button("Delete \(noun)", role: .destructive) {
            model.delete(item)
        }
        .disabled(!mine)
    }
}

/// The source kinds, for the add menus.
struct AddSourceItems: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("AddSourceItems")
        ForEach(SourceKind.allCases) { kind in
            Button(kind.title, systemImage: kind.symbol) { model.addSource(kind) }
        }
    }
}

/// The detector kinds, for the add menus.
struct AddDetectorItems: View {
    let model: AppState

    var body: some View {
        let _ = PerfProbe.body("AddDetectorItems")
        ForEach(DetectorKind.allCases) { kind in
            Button(kind.title, systemImage: kind.symbol) { model.addDetector(kind) }
        }
    }
}
