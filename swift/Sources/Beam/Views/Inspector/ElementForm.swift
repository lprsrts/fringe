import SwiftUI

struct ElementForm: View {
    let model: AppState
    let id: String

    var body: some View {
        if let element = model.scene[element: id], let index = model.scene.elementIndex(id) {
            let lambda = model.scene.lambdaB
            let domain = model.scene.domain

            Section {
                TextField("Name", text: model.elementBinding(id, "Rename Element", \.name, fallback: ""))
                Toggle("Enabled", isOn: model.elementBinding(id, element.enabled ? "Disable Element" : "Enable Element", \.enabled, fallback: true))
                    .toggleStyle(.switch)
                IssueLines(issues: model.elementIssues(index, key: nil))
                LengthField(
                    title: "Position x",
                    value: model.elementBinding(id, "Move Element", \.xUm, fallback: 0),
                    lambda: lambda,
                    range: domain.xMinUm...domain.xMaxUm,
                    issues: model.elementIssues(index, key: "x_um"),
                    onEditingChanged: model.editingChanged("Move Element")
                )
                LengthField(
                    title: "Position y",
                    value: model.elementBinding(id, "Move Element", \.yUm, fallback: 0),
                    lambda: lambda,
                    range: domain.yMinUm...domain.yMaxUm,
                    issues: model.elementIssues(index, key: "y_um"),
                    onEditingChanged: model.editingChanged("Move Element")
                )
                ValueRow(
                    title: "Rotation",
                    value: model.elementBinding(id, "Rotate Element", \.rotationDeg, fallback: 0),
                    range: -180...180,
                    limits: -360...360,
                    unit: "°",
                    digits: 1,
                    neutral: 0,
                    onEditingChanged: model.editingChanged("Rotate Element")
                )
            } header: {
                Label(element.kind.title, systemImage: element.kind.symbol)
            }

            MaterialSection(model: model, id: id, element: element, index: index)

            Section("Shape") {
                ShapeFields(model: model, id: id, element: element, index: index)
            }

            DerivedSection(model: model, element: element)

            Section {
                Button("Duplicate Element") {
                    model.selection = .element(id)
                    model.duplicateSelectedElement()
                }
                Button("Delete Element", role: .destructive) {
                    model.deleteElement(id)
                }
            }
        }
    }
}

// MARK: - Material

private struct MaterialSection: View {
    let model: AppState
    let id: String
    let element: Element
    let index: Int

    var body: some View {
        let material = element.material
        Section {
            Picker("Material", selection: model.elementBinding(id, "Change Material", \.material.kind, fallback: .dielectric)) {
                Text("Dielectric").tag(MaterialKind.dielectric)
                Text("PEC").tag(MaterialKind.pec)
            }
            .pickerStyle(.segmented)
            .disabled(element.requiresPEC)

            if !material.isPEC {
                LabeledContent("Preset") {
                    Menu(MaterialPreset.matching(material)?.name ?? "Custom") {
                        ForEach(MaterialPreset.all) { preset in
                            Button("\(preset.name) (n \(SceneFormat.fixed(preset.n, 3)))") {
                                model.edit("Change Material") { doc in
                                    doc.scene[element: id]?.material = .glass(preset.n)
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
                ValueRow(
                    title: "Refractive Index n",
                    value: model.elementBinding(id, "Change Refractive Index", \.material.n, fallback: 1.5),
                    range: 1...4,
                    limits: 1...6,
                    digits: 3,
                    onEditingChanged: model.editingChanged("Change Refractive Index")
                )
                IssueLines(issues: model.elementIssues(index, key: "n"))
                ValueRow(
                    title: "Extinction k",
                    value: model.elementBinding(id, "Change Extinction", \.material.k, fallback: 0),
                    range: 0...0.2,
                    limits: 0...1,
                    digits: 3,
                    onEditingChanged: model.editingChanged("Change Extinction")
                )
                IssueLines(issues: model.elementIssues(index, key: "k"))
            }
            IssueLines(issues: model.elementIssues(index, key: "material"))
        } header: {
            Text("Material")
        } footer: {
            if element.requiresPEC {
                Text("\(element.kind.title) elements are perfect electric conductors.")
                    .foregroundStyle(.secondary)
            } else if material.isPEC {
                Text("A perfect electric conductor: the field is zero inside.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Indices are approximate, near 633 nm. k > 0 absorbs.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shape

private struct ShapeFields: View {
    let model: AppState
    let id: String
    let element: Element
    let index: Int

    private var lambda: Double { model.scene.lambdaB }

    /// A shape parameter, e.g. `field(\.lens, \.apertureUm, ...)`.
    private func binding<S, V>(_ shape: WritableKeyPath<Shape, S>, _ field: WritableKeyPath<S, V>, _ name: String, fallback: V) -> Binding<V> {
        model.elementBinding(id, name, (\Element.shape).appending(path: shape).appending(path: field), fallback: fallback)
    }

    private func length<S>(
        _ title: String,
        _ shape: WritableKeyPath<Shape, S>,
        _ field: WritableKeyPath<S, Double>,
        key: String,
        range: ClosedRange<Double>
    ) -> some View {
        let name = "Change \(title)"
        return LengthField(
            title: title,
            value: binding(shape, field, name, fallback: 1),
            lambda: lambda,
            range: range,
            limits: 0...1e5,
            issues: model.elementIssues(index, key: key),
            onEditingChanged: model.editingChanged(name)
        )
    }

    private var span: Double { max(model.scene.domain.width, model.scene.domain.height) }

    var body: some View {
        switch element.shape {
        case .lens(let lens):
            LensPresetRow(model: model, id: id, lens: lens)
            OptionalRadiusField(
                model: model, id: id, title: "Front Radius R₁", flatTitle: "Flat front surface", path: \Element.shape.lens.r1Um, flatDefault: 12,
                issues: model.elementIssues(index, key: "r1_um")
            )
            OptionalRadiusField(
                model: model, id: id, title: "Back Radius R₂", flatTitle: "Flat back surface", path: \Element.shape.lens.r2Um, flatDefault: -12,
                issues: model.elementIssues(index, key: "r2_um")
            )
            length("Center Thickness", \.lens, \.centerThicknessUm, key: "center_thickness_um", range: 0.1...max(10, span / 4))
            length("Aperture", \.lens, \.apertureUm, key: "aperture_um", range: 0.5...max(10, span))
        case .slab:
            length("Thickness", \.slab, \.thicknessUm, key: "thickness_um", range: 0.05...max(10, span / 2))
            length("Height", \.slab, \.heightUm, key: "height_um", range: 0.5...max(10, span))
        case .wedge:
            length("Thick Side", \.wedge, \.thickUm, key: "thick_um", range: 0.1...max(10, span / 2))
            length("Thin Side", \.wedge, \.thinUm, key: "thin_um", range: 0.05...max(10, span / 2))
            length("Height", \.wedge, \.heightUm, key: "height_um", range: 0.5...max(10, span))
        case .prism:
            length("Base", \.prism, \.baseUm, key: "base_um", range: 0.5...max(10, span))
            ValueRow(
                title: "Apex Angle",
                value: binding(\.prism, \.apexDeg, "Change Apex Angle", fallback: 60),
                range: 5...170,
                limits: 1...179,
                unit: "°",
                digits: 1,
                onEditingChanged: model.editingChanged("Change Apex Angle")
            )
            IssueLines(issues: model.elementIssues(index, key: "apex_deg"))
        case .mirror:
            length("Aperture", \.mirror, \.apertureUm, key: "aperture_um", range: 0.5...max(10, span))
            length("Thickness", \.mirror, \.thicknessUm, key: "thickness_um", range: 0.05...5)
            OptionalRadiusField(
                model: model, id: id, title: "Radius R", flatTitle: "Flat mirror", path: \Element.shape.mirror.radiusUm, flatDefault: 20,
                issues: model.elementIssues(index, key: "radius_um")
            )
        case .slits(let slits):
            CountRow(title: "Slits", value: binding(\.slits, \.count, "Change Slit Count", fallback: 2), range: 1...64)
            IssueLines(issues: model.elementIssues(index, key: "count"))
            length("Slit Width", \.slits, \.slitWidthUm, key: "slit_width_um", range: 0.1...max(5, span / 4))
            if slits.count > 1 {
                length("Pitch", \.slits, \.pitchUm, key: "pitch_um", range: 0.2...max(10, span / 2))
            }
            length("Screen Height", \.slits, \.screenHeightUm, key: "screen_height_um", range: 1...max(10, span))
            length("Thickness", \.slits, \.thicknessUm, key: "thickness_um", range: 0.05...5)
        case .grating:
            length("Period", \.grating, \.periodUm, key: "period_um", range: 0.2...max(10, span / 4))
            ValueRow(
                title: "Fill Factor",
                value: binding(\.grating, \.fillFactor, "Change Fill Factor", fallback: 0.5),
                range: 0.05...0.95,
                limits: 0.01...0.99,
                digits: 2,
                onEditingChanged: model.editingChanged("Change Fill Factor")
            )
            IssueLines(issues: model.elementIssues(index, key: "fill_factor"))
            length("Depth", \.grating, \.depthUm, key: "depth_um", range: 0.05...max(5, span / 4))
            CountRow(title: "Bars", value: binding(\.grating, \.count, "Change Bar Count", fallback: 7), range: 1...200)
            IssueLines(issues: model.elementIssues(index, key: "count"))
            length("Substrate", \.grating, \.substrateUm, key: "substrate_um", range: 0...max(5, span / 4))
        case .cylinder:
            length("Radius", \.cylinder, \.radiusUm, key: "radius_um", range: 0.05...max(5, span / 2))
        case .waveguide:
            length("Width", \.waveguide, \.widthUm, key: "width_um", range: 0.05...max(5, span / 4))
            length("Length", \.waveguide, \.lengthUm, key: "length_um", range: 0.5...max(10, span))
        case .polygon(let polygon):
            PolygonVerticesField(model: model, id: id, polygon: polygon)
            IssueLines(issues: model.elementIssues(index, key: "vertices_um"))
        }
    }
}

private struct CountRow: View {
    let title: String
    let value: Binding<Int>
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: value, in: range) {
            LabeledContent(title, value: "\(value.wrappedValue)")
                .monospacedDigit()
        }
    }
}

/// A lens or mirror radius that may be flat (null in the scene).
private struct OptionalRadiusField: View {
    let model: AppState
    let id: String
    let title: String
    /// Checkbox title in sentence case, such as "Flat front surface".
    let flatTitle: String
    let path: WritableKeyPath<Element, Double?>
    /// Used when the surface stops being flat.
    let flatDefault: Double
    var issues: [Issue] = []

    var body: some View {
        let radius = model.elementBinding(id, "Change \(title)", path, fallback: nil)
        let isFlat = radius.wrappedValue == nil
        VStack(alignment: .leading, spacing: 4) {
                Toggle(flatTitle, isOn: Binding(
                    get: { isFlat },
                    set: { flat in radius.wrappedValue = flat ? nil : flatDefault }
                ))
                if !isFlat {
                    LengthField(
                        title: title,
                        value: Binding(get: { radius.wrappedValue ?? flatDefault }, set: { radius.wrappedValue = $0 }),
                        lambda: model.scene.lambdaB,
                        limits: -1e5...1e5,
                        issues: issues
                    )
                    Text("Positive: center of curvature on the +x side of the element.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    IssueLines(issues: issues)
                }
        }
    }
}

private struct LensPresetRow: View {
    let model: AppState
    let id: String
    let lens: Lens

    private enum Preset: String, CaseIterable {
        case biconvex = "Biconvex"
        case planoConvex = "Plano-Convex"
        case planoConcave = "Plano-Concave"
        case biconcave = "Biconcave"
        case meniscus = "Meniscus"

        func radii(magnitude r: Double) -> (Double?, Double?) {
            switch self {
            case .biconvex: return (r, -r)
            case .planoConvex: return (r, nil)
            case .planoConcave: return (-r, nil)
            case .biconcave: return (-r, r)
            case .meniscus: return (r, 2 * r)
            }
        }

        static func matching(_ lens: Lens) -> Preset? {
            switch (lens.r1Um.map { $0 > 0 }, lens.r2Um.map { $0 > 0 }) {
            case (true?, false?): return .biconvex
            case (true?, nil): return .planoConvex
            case (false?, nil): return .planoConcave
            case (false?, true?): return .biconcave
            case (true?, true?): return .meniscus
            default: return nil
            }
        }
    }

    var body: some View {
        LabeledContent("Lens Shape") {
            Menu(Preset.matching(lens)?.rawValue ?? "Custom") {
                ForEach(Preset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) {
                        let magnitude = max(abs(lens.r1Um ?? 0), abs(lens.r2Um ?? 0), 0.6 * lens.apertureUm + 1)
                        let (r1, r2) = preset.radii(magnitude: magnitude)
                        model.edit("Change Lens Shape") { doc in
                            doc.scene[element: id]?.shape.lens.r1Um = r1
                            doc.scene[element: id]?.shape.lens.r2Um = r2
                        }
                    }
                }
            }
            .fixedSize()
        }
    }
}

/// Polygon vertices as JSON, `[[x, y], …]` in the element's frame.
private struct PolygonVerticesField: View {
    let model: AppState
    let id: String
    let polygon: Polygon

    @UIState private var text = ""
    @UIState private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Vertices (µm, element frame)")
            TextField("Vertices", text: $text, axis: .vertical)
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...10)
                .focused($isFocused)
                .onSubmit(commit)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("JSON pairs such as [[-2, -2], [2, -2], [0, 2]]. Press Return to apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { text = Self.format(polygon) }
        .onChange(of: polygon) { _, newValue in
            if !isFocused { text = Self.format(newValue) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        guard let data = text.data(using: .utf8),
              let vertices = try? JSONDecoder().decode([[Double]].self, from: data),
              vertices.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
            error = "Not a list of [x, y] pairs."
            return
        }
        error = nil
        guard vertices != polygon.verticesUm else { return }
        model.edit("Change Vertices") { doc in
            doc.scene[element: id]?.shape.polygon.verticesUm = vertices
        }
    }

    /// JSON text, so always with a decimal point whatever the locale.
    static func format(_ polygon: Polygon) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        let number = { (v: Double) in
            Format.number(v, digits: 0...4, locale: posix).replacingOccurrences(of: "−", with: "-")
        }
        return "[" + polygon.verticesUm.map { "[\(number($0.first ?? 0)), \(number($0.last ?? 0))]" }.joined(separator: ", ") + "]"
    }
}

// MARK: - Derived

private struct DerivedSection: View {
    let model: AppState
    let element: Element

    var body: some View {
        if let info = model.checkReport?.derived?.element(element.id) {
            let rows = Self.rows(info, element: element)
            if !rows.isEmpty {
                Section("Derived") {
                    ForEach(rows, id: \.title) { row in
                        LabeledContent(row.title) {
                            Text(row.value).foregroundStyle(row.isInvalid ? .red : .secondary)
                        }
                    }
                }
                .monospacedDigit()
            }
        }
    }

    struct Row {
        var title: String
        var value: String
        var isInvalid = false
    }

    static func rows(_ info: Derived.ElementInfo, element: Element) -> [Row] {
        var rows: [Row] = []
        if let lens = info.lens {
            rows.append(Row(title: "Paraxial Focal Length", value: lens.paraxialFocalUm.map { Format.micrometres($0) } ?? "No power"))
            if let bfl = lens.backFocalUm {
                rows.append(Row(title: "Back Focal Length", value: Format.micrometres(bfl)))
            }
            if let edge = lens.edgeThicknessUm {
                rows.append(Row(title: "Edge Thickness", value: Format.micrometres(edge), isInvalid: edge <= 0))
            }
        }
        if let mirror = info.mirror {
            rows.append(Row(title: "Focal Length", value: mirror.focalUm.map { Format.micrometres($0) } ?? "Flat"))
        }
        if let grating = info.grating {
            let orders = grating.orders.map { "\($0.m > 0 ? "+" : "")\($0.m): \(Format.degrees($0.angleDeg))" }
            rows.append(Row(title: "Propagating Orders", value: "\(grating.orders.count)"))
            if !orders.isEmpty {
                rows.append(Row(title: "Order Angles", value: orders.joined(separator: ", ")))
            }
        }
        if let slits = info.slits {
            rows.append(Row(title: "First Single-Slit Null", value: slits.singleSlitNullDeg.map { Format.degrees($0) } ?? "None"))
            if let spacing = slits.fringeSpacingDeg {
                rows.append(Row(title: "Fringe Spacing", value: Format.degrees(spacing, digits: 2)))
            }
        }
        if let cylinder = info.cylinder {
            rows.append(Row(title: "Size Parameter k·r", value: Format.number(cylinder.sizeParameter, digits: 2...2)))
        }
        if let waveguide = info.waveguide {
            rows.append(Row(title: "V Number", value: Format.number(waveguide.vNumber, digits: 2...2)))
            rows.append(Row(title: "Guided Modes", value: "\(waveguide.guidedModes)"))
        }
        if let prism = info.prism {
            rows.append(Row(title: "Minimum Deviation", value: prism.minDeviationDeg.map { Format.degrees($0) } ?? "Total internal reflection"))
        }
        return rows
    }
}
