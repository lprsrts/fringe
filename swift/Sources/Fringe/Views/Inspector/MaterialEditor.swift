import SwiftUI

/// An element's material: a constant index n + ik, a Lorentz–Drude model (from the core's
/// presets or edited pole by pole, with an n and k chart), or a perfect electric conductor.
struct MaterialEditor: View {
    let model: AppState
    let id: String
    let element: Element
    let index: Int

    private var material: Material { element.material }
    private var lambda0: Double { model.scene.wavelengthUm }

    var body: some View {
        let _ = PerfProbe.body("MaterialEditor")
        Section {
            Picker("Material", selection: kindBinding) {
                ForEach(MaterialKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(element.requiresPEC)
            .help("Constant index, a dispersive Lorentz–Drude model, or a perfect conductor")

            switch material.kind {
            case .dielectric:
                indexFields
            case .dispersive:
                dispersiveFields
            case .pec:
                EmptyView()
            }
            IssueLines(issues: model.elementIssues(index, key: "material"))
        } header: {
            Text("Material")
        } footer: {
            footer
        }

        if material.kind == .dispersive {
            Section {
                ForEach(Array(material.poles.enumerated()), id: \.offset) { k, pole in
                    PoleEditor(model: model, elementID: id, index: k, pole: pole, issues: poleIssues(k))
                }
                if material.poles.isEmpty {
                    Text("No poles: the material is a constant ε∞.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Poles")
                    Spacer()
                    Menu {
                        Button("Add Drude Pole") { addPole(.drude(plasmaEv: 9, gammaEv: 0.07)) }
                        Button("Add Lorentz Pole") { addPole(.lorentz(strength: 1, resonanceEv: 4, gammaEv: 0.5)) }
                    } label: {
                        Label("Add Pole", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(material.poles.count >= Material.maxPoles)
                    .help(material.poles.count >= Material.maxPoles ? "A model has at most \(Material.maxPoles) poles" : "Add a pole")
                }
            } footer: {
                MathText.footer(#"Energies are $\hbar\omega$ in eV (1.24 eV at 1 µm). Drude: $-\omega_p^2/(\omega^2 + \mathrm{i}\gamma\omega)$. Lorentz: $\Delta\varepsilon\,\omega_0^2/(\omega_0^2 - \omega^2 - \mathrm{i}\gamma\omega)$."#)
                    .foregroundStyle(.secondary)
            }
            // A fresh identity when poles come or go, so no row keeps a removed pole's binding.
            .id(material.poles.map(\.isDrude))

            // The preset's citation closes the material, under the curve it is about.
            Section {
                curveRows
            } header: {
                Text("n and k")
            } footer: {
                dispersiveFooter
            }
        }
    }

    // MARK: Kind

    private var kindBinding: Binding<MaterialKind> {
        Binding(
            get: { material.kind },
            set: { kind in
                guard kind != material.kind else { return }
                model.edit("Change Material") { doc in
                    guard var m = doc.scene[element: id]?.material else { return }
                    if kind == .dispersive, m.poles.isEmpty {
                        // A lossless model close to the current index, to edit from.
                        let seed = Material.seededDispersive(n: m.n)
                        m.epsInf = seed.epsInf
                        m.poles = seed.poles
                        m.preset = nil
                    }
                    m.kind = kind
                    doc.scene[element: id]?.setMaterial(m)
                }
            }
        )
    }

    // MARK: Index

    @ViewBuilder
    private var indexFields: some View {
        LabeledContent("Preset") {
            Menu(MaterialPreset.matching(material).map { "\($0.name) (n \(SceneFormat.fixed($0.n, 3)))" } ?? "Custom") {
                ForEach(MaterialPreset.all) { preset in
                    Button("\(preset.name) (n \(SceneFormat.fixed(preset.n, 3)))") {
                        model.edit("Change Material") { doc in
                            guard var m = doc.scene[element: id]?.material else { return }
                            m.kind = .dielectric
                            m.n = preset.n
                            m.k = 0
                            doc.scene[element: id]?.setMaterial(m)
                        }
                    }
                }
                if !model.materialLibrary.isEmpty {
                    Section("Dispersive") {
                        libraryButtons
                    }
                }
            }
            .fixedSize()
            .help("Constant indices near 633 nm; a dispersive preset switches to Lorentz–Drude")
        }
        ValueRow(
            title: "Refractive Index $n$",
            value: model.elementBinding(id, "Change Refractive Index", \.material.n, fallback: 1.5),
            range: 1...4,
            limits: 1...6,
            digits: 3,
            onEditingChanged: model.editingChanged("Change Refractive Index")
        )
        IssueLines(issues: model.elementIssues(index, key: "n"))
        ValueRow(
            title: "Extinction $k$",
            value: model.elementBinding(id, "Change Extinction", \.material.k, fallback: 0),
            range: 0...0.2,
            limits: 0...1,
            digits: 3,
            onEditingChanged: model.editingChanged("Change Extinction")
        )
        IssueLines(issues: model.elementIssues(index, key: "k"))
    }

    // MARK: Lorentz–Drude

    private var presetEntry: MaterialLibraryEntry? {
        material.preset.flatMap { id in model.materialLibrary.first { $0.id == id } }
    }

    /// The preset's numbers have been changed.
    private var isEdited: Bool {
        guard let entry = presetEntry else { return false }
        return !material.sameModel(as: entry.material)
    }

    private var presetTitle: String {
        guard let preset = material.preset else { return "Custom" }
        let name = MaterialLibrary.displayName(of: preset)
        return isEdited ? "\(name) (edited)" : name
    }

    @ViewBuilder
    private var libraryButtons: some View {
        ForEach(model.materialLibrary) { entry in
            Button(entry.name) { applyPreset(entry) }
        }
    }

    private func applyPreset(_ entry: MaterialLibraryEntry) {
        model.edit("Change Material") { doc in
            doc.scene[element: id]?.setMaterial(entry.material)
        }
    }

    @ViewBuilder
    private var dispersiveFields: some View {
        LabeledContent("Preset") {
            Menu(presetTitle) {
                let metals = model.materialLibrary.filter(\.isMetal)
                let glasses = model.materialLibrary.filter { !$0.isMetal }
                if !metals.isEmpty {
                    Section("Metals") {
                        ForEach(metals) { entry in Button(entry.name) { applyPreset(entry) } }
                    }
                }
                if !glasses.isEmpty {
                    Section("Glasses") {
                        ForEach(glasses) { entry in Button(entry.name) { applyPreset(entry) } }
                    }
                }
                if isEdited, let entry = presetEntry {
                    Divider()
                    Button("Revert to Preset") { applyPreset(entry) }
                }
            }
            .fixedSize()
            .help("Lorentz–Drude fits to measured data")
        }
        ValueRow(
            title: #"High-Frequency $\varepsilon_\infty$"#,
            value: model.elementBinding(id, "Change Background Permittivity", \.material.epsInf, fallback: 1),
            range: 1...10,
            limits: 1...100,
            digits: 3,
            onEditingChanged: model.editingChanged("Change Background Permittivity")
        )
        IssueLines(issues: model.elementIssues(index, key: "eps_inf") + model.elementIssues(index, key: "poles"))
    }

    private func addPole(_ pole: Pole) {
        model.edit("Add Pole") { doc in
            guard (doc.scene[element: id]?.material.poles.count ?? Material.maxPoles) < Material.maxPoles else { return }
            doc.scene[element: id]?.material.poles.append(pole)
        }
    }

    private func poleIssues(_ k: Int) -> [Issue] {
        let prefix = "elements[\(index)].material.poles[\(k)]"
        return model.checkReport?.issues.filter { $0.path == prefix || $0.path.hasPrefix(prefix + ".") } ?? []
    }

    // MARK: Chart and value at λ0

    @ViewBuilder
    private var curveRows: some View {
        let curve = MaterialCurveCache.shared.curve(for: material, lambda0: lambda0)
        if let curve {
            if !MaterialChart.isConstant(curve) {
                MaterialChart(curve: curve, lambda0: lambda0, validRange: isEdited || presetEntry == nil ? nil : presetEntry?.rangeUm,
                              materialName: material.preset.map { MaterialLibrary.displayName(of: $0) })
                    .padding(.vertical, 4)
            }
        } else {
            let range = MaterialChart.range(lambda0: lambda0)
            Text("This model cannot be evaluated over \(MaterialChart.exact(range.lowerBound))–\(MaterialChart.exact(range.upperBound)) µm.")
                .foregroundStyle(.secondary)
        }
        if let at = curve?.at ?? model.checkReport?.derived?.element(id)?.material {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    MathText("$n$ " + Self.complex(at.n, at.k))
                    MathText(#"$\varepsilon$ "# + Self.complex(at.eps1, at.eps2))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            } label: {
                MathText(#"At $\lambda_0$ = "# + MaterialChart.wavelength(lambda0))
            }
        }
        if let curve, MaterialChart.isConstant(curve) {
            Text("The same at every wavelength.")
                .foregroundStyle(.secondary)
        }
    }

    /// "0.18 + 3.07i" with the i set upright, for `MathText`.
    static func complex(_ re: Double, _ im: Double) -> String {
        let sign = im < 0 ? "−" : "+"
        return "\(Format.number(re, digits: 2...2)) \(sign) \(Format.number(abs(im), digits: 2...2))" + #"$\mathrm{i}$"#
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if element.requiresPEC {
            Text("\(element.kind.title) elements are perfect electric conductors.")
                .foregroundStyle(.secondary)
        } else {
            switch material.kind {
            case .pec:
                Text("A perfect electric conductor: the field is zero inside.")
                    .foregroundStyle(.secondary)
            case .dielectric:
                MathText.footer("Indices are approximate, near 633 nm. $k > 0$ absorbs.")
                    .foregroundStyle(.secondary)
            case .dispersive:
                EmptyView()
            }
        }
    }

    /// Where a preset's numbers come from, or what a custom model is.
    @ViewBuilder
    private var dispersiveFooter: some View {
        if let entry = presetEntry, !entry.source.isEmpty {
            Text(entry.source.hasSuffix(".") ? entry.source : entry.source + ".")
                .foregroundStyle(.secondary)
        } else {
            Text("A Lorentz–Drude model, evaluated at the scene wavelength.")
                .foregroundStyle(.secondary)
        }
    }
}
