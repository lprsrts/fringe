import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) private var model

    var body: some View {
        Form {
            switch model.selection {
            case .beam:
                BeamInspector(model: model)
            case .element(let id):
                if model.scene[element: id] != nil {
                    ElementInspector(model: model, id: id)
                } else {
                    BeamInspector(model: model)
                }
            case .appearance:
                AppearanceInspector(model: model)
            case .output:
                OutputInspector(model: model)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LaserLine: Identifiable {
    let wavelength: Double
    var source: String?
    var id: Double { wavelength }

    var name: String {
        let value = Format.wavelength(wavelength)
        return source.map { "\(value) (\($0))" } ?? value
    }

    static let all = [
        LaserLine(wavelength: 405e-9),
        LaserLine(wavelength: 488e-9),
        LaserLine(wavelength: 532e-9),
        LaserLine(wavelength: 632.8e-9, source: "He-Ne"),
        LaserLine(wavelength: 1064e-9, source: "Nd:YAG"),
    ]
}

private struct BeamInspector: View {
    let model: AppState

    var body: some View {
        let beam = model.beam
        let visible = model.window.zMin * 100...model.window.zMax * 100

        Section("Beam") {
            ValueRow(
                title: "Wavelength",
                value: model.binding("Change Wavelength", \.beam.wavelength).scaled(by: 1e9),
                range: 380...1100,
                limits: 200...2000,
                unit: "nm",
                digits: 1,
                ticks: LaserLine.all.map { $0.wavelength * 1e9 },
                onEditingChanged: model.editingChanged("Change Wavelength")
            )
            LabeledContent("Laser Line") {
                Menu(currentLaserLine?.name ?? "Other") {
                    ForEach(LaserLine.all) { line in
                        Button(line.name) {
                            model.edit("Change Wavelength") { $0.beam.wavelength = line.wavelength }
                        }
                    }
                }
                .fixedSize()
            }
            ValueRow(
                title: "Waist Radius w₀",
                value: model.binding("Change Waist Radius", \.beam.w0).scaled(by: 1000),
                range: 0.05...2,
                limits: 0.001...100,
                unit: "mm",
                digits: 3,
                onEditingChanged: model.editingChanged("Change Waist Radius")
            )
            ValueRow(
                title: "Waist Position z₀",
                value: model.binding("Change Waist Position", \.beam.z0).scaled(by: 100),
                range: visible,
                unit: "cm",
                digits: 1,
                onEditingChanged: model.editingChanged("Change Waist Position")
            )
            ValueRow(
                title: "Refractive Index n",
                value: model.binding("Change Refractive Index", \.beam.refractiveIndex),
                range: 1...2.4,
                limits: 1...5,
                digits: 3,
                onEditingChanged: model.editingChanged("Change Refractive Index")
            )
        }

        Section("Derived") {
            LabeledContent("Rayleigh Range", value: Format.length(beam.rayleighRange))
            LabeledContent("Confocal Parameter", value: Format.length(2 * beam.rayleighRange))
            LabeledContent(
                "Divergence",
                value: "\(Format.number(beam.divergenceHalfAngle * 1000, digits: 2...2)) mrad (\(Format.number(beam.divergenceHalfAngle * 180 / .pi, digits: 2...2))°)"
            )
        }
        .monospacedDigit()
    }

    private var currentLaserLine: LaserLine? {
        LaserLine.all.first { abs($0.wavelength - model.beam.wavelength) < 0.05e-9 }
    }
}

private struct ElementInspector: View {
    let model: AppState
    let id: UUID

    var body: some View {
        if let element = model.scene[element: id] {
            let visible = model.window.zMin * 100...model.window.zMax * 100

            Section {
                TextField("Name", text: model.elementBinding(id, "Rename Element", \.name, fallback: ""))
                Toggle("Enabled", isOn: model.elementBinding(id, element.isEnabled ? "Disable Element" : "Enable Element", \.isEnabled, fallback: true))
                    .toggleStyle(.switch)
                ValueRow(
                    title: "Position z",
                    value: model.elementBinding(id, "Move Element", \.z, fallback: 0).scaled(by: 100),
                    range: visible,
                    unit: "cm",
                    digits: 1,
                    onEditingChanged: model.editingChanged("Move Element")
                )
                parameterRows(for: element.type)
            } header: {
                Text(element.type.displayName)
            } footer: {
                if element.type == .flatMirror {
                    Text("Folds the beam without changing it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Duplicate Element") {
                    model.duplicateSelectedElement()
                }
                Button("Delete Element", role: .destructive) {
                    model.deleteSelectedElement()
                }
            }
        }
    }

    @ViewBuilder
    private func parameterRows(for type: OpticalElementType) -> some View {
        switch type {
        case .thinLens:
            parameterRow("Focal Length", \.param1, scale: 1000, range: -500...500, unit: "mm", digits: 0, neutral: 0, minimumMagnitude: 1)
        case .curvedMirror:
            parameterRow("Radius of Curvature", \.param1, scale: 1000, range: -1000...1000, unit: "mm", digits: 0, neutral: 0, minimumMagnitude: 1)
        case .flatMirror:
            EmptyView()
        case .dielectricInterface:
            parameterRow("Index Before", \.param1, range: 1...2.5, limits: 1...5, digits: 3)
            parameterRow("Index After", \.param2, range: 1...2.5, limits: 1...5, digits: 3)
        case .gaussianAperture:
            parameterRow("Aperture Radius", \.param1, scale: 1000, range: 0.1...3, limits: 0.001...100, unit: "mm", digits: 2)
        }
    }

    private func parameterRow(
        _ title: String,
        _ keyPath: WritableKeyPath<PlacedElementModel, Double>,
        scale: Double = 1,
        range: ClosedRange<Double>,
        limits: ClosedRange<Double>? = nil,
        unit: String = "",
        digits: Int,
        neutral: Double? = nil,
        minimumMagnitude: Double? = nil
    ) -> ValueRow {
        let name = "Change \(title)"
        var row = ValueRow(
            title: title,
            value: model.elementBinding(id, name, keyPath, fallback: 0).scaled(by: scale),
            range: range,
            unit: unit,
            digits: digits,
            neutral: neutral,
            onEditingChanged: model.editingChanged(name)
        )
        if let limits { row.limits = limits }
        row.minimumMagnitude = minimumMagnitude
        return row
    }
}

private struct AppearanceInspector: View {
    let model: AppState

    var body: some View {
        Section("Color") {
            Picker("Colormap", selection: model.binding("Change Colormap", \.style.colormap)) {
                ForEach(ColormapOption.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            ValueRow(
                title: "Gamma",
                value: model.binding("Change Gamma", \.style.gamma),
                range: 0.3...2.5,
                limits: 0.05...10,
                digits: 2,
                neutral: 1,
                onEditingChanged: model.editingChanged("Change Gamma")
            )
        }

        Section("Phase Fringes") {
            Toggle("Show fringes", isOn: model.binding("Show Fringes", \.style.showWavefrontComposite))
            ValueRow(
                title: "Fringe Depth",
                value: model.binding("Change Fringe Depth", \.style.fringeModulation).scaled(by: 100),
                range: 0...100,
                limits: 0...100,
                unit: "%",
                digits: 0,
                onEditingChanged: model.editingChanged("Change Fringe Depth")
            )
            .disabled(!model.style.showWavefrontComposite)
        }

        Section("Overlays") {
            OverlayToggles(model: model, inMenu: false)
        }
    }
}

private struct OutputInspector: View {
    let model: AppState

    var body: some View {
        let output = model.output
        let size = model.outputPixelSize
        let megapixels = Double(size.width * size.height) / 1_000_000

        Section("Format") {
            Picker("Aspect Ratio", selection: model.binding("Change Aspect Ratio", \.output.aspect)) {
                ForEach(OutputAspect.presets, id: \.self) { Text($0.title).tag($0) }
                Text("Custom").tag(output.aspect.asCustom)
            }
            if case .custom(let width, let height) = output.aspect {
                LabeledContent("Ratio") {
                    HStack(spacing: 4) {
                        ratioField("Ratio Width", value: width) { .custom(width: $0, height: height) }
                        Text(":").foregroundStyle(.secondary)
                        ratioField("Ratio Height", value: height) { .custom(width: width, height: $0) }
                    }
                }
            }
            Picker("Size", selection: model.binding("Change Size", \.output.longEdge)) {
                ForEach(LongEdge.presets, id: \.self) { Text("\($0.pixels) px").tag($0) }
                Text("Custom").tag(LongEdge.custom(output.longEdge.pixels))
            }
            if output.longEdge.isCustom {
                LabeledContent("Long Edge") {
                    HStack(spacing: 4) {
                        TextField("Long Edge", value: customLongEdge, format: .number.grouping(.never))
                            .labelsHidden()
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("px").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Pixels", value: "\(size.width) × \(size.height) · \(Format.number(megapixels, digits: 1...1)) MP")
                .monospacedDigit()
        }

        Section("Frame") {
            LabeledContent("Axial Start") { metresField("Axial Start", edge: \.zMin) }
            LabeledContent("Axial End") { metresField("Axial End", edge: \.zMax) }
            ValueRow(
                title: "Transverse Half-Height",
                value: halfHeight.scaled(by: 1000),
                range: 0.05...20,
                limits: 0.001...1000,
                unit: "mm",
                digits: 3,
                logarithmic: true,
                onEditingChanged: model.editingChanged("Change Frame Height")
            )
            ValueRow(
                title: "Zoom",
                value: model.binding("Zoom", \.framing.zoomScale),
                range: FramingModel.zoomRange,
                limits: FramingModel.zoomRange,
                unit: "×",
                digits: 2,
                neutral: 1,
                logarithmic: true,
                onEditingChanged: model.editingChanged("Zoom")
            )
            Button("Zoom to Fit") { model.zoomToFit() }
        }
    }

    private func ratioField(_ title: String, value: Int, aspect: @escaping (Int) -> OutputAspect) -> some View {
        TextField(title, value: Binding(
            get: { value },
            set: { term in
                let term = min(OutputAspect.customTermRange.upperBound, max(OutputAspect.customTermRange.lowerBound, term))
                model.edit("Change Aspect Ratio") { $0.output.aspect = aspect(term) }
            }
        ), format: .number.grouping(.never))
        .labelsHidden()
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .frame(width: 44)
    }

    private var customLongEdge: Binding<Int> {
        Binding(
            get: { model.output.longEdge.pixels },
            set: { pixels in model.edit("Change Size") { $0.output.longEdge = .custom(pixels) } }
        )
    }

    /// The visible transverse half-height, kept when zoom changes are folded back in.
    private var halfHeight: Binding<Double> {
        let base = model.binding("Change Frame Height", \.framing.xMax)
        return Binding(
            get: { model.framing.effectiveXMax },
            set: { base.wrappedValue = $0 * model.framing.zoomScale }
        )
    }

    private func metresField(_ title: String, edge: KeyPath<FrameWindow, Double>) -> some View {
        let value = Binding<Double>(
            get: { model.window[keyPath: edge] },
            set: { newValue in
                let window = model.window
                let isStart = edge == \FrameWindow.zMin
                let start = isStart ? newValue : window.zMin
                let end = isStart ? window.zMax : newValue
                model.setAxialRange(start: start, end: end)
            }
        )
        return HStack(spacing: 4) {
            TextField(title, value: value, format: .number.precision(.fractionLength(3)).grouping(.never))
                .labelsHidden()
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text("m").foregroundStyle(.secondary).frame(minWidth: 20, alignment: .leading)
        }
    }
}
