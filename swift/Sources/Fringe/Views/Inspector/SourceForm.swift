import SwiftUI

/// One source: a Gaussian beam, a plane wave or a point emitter.
struct SourceForm: View {
    let model: AppState
    let id: String

    var body: some View {
        let _ = PerfProbe.body("SourceForm")
        if let source = model.scene[source: id], let index = model.scene.sourceIndex(id) {
            let scene = model.scene
            let lambda = scene.lambdaB
            let domain = scene.domain

            Section {
                TextField("Name", text: model.sourceBinding(id, "Rename Source", \.name, fallback: ""), prompt: Text(source.kind.rowTitle))
                Toggle("Enabled", isOn: model.sourceBinding(id, source.enabled ? "Disable Source" : "Enable Source", \.enabled, fallback: true))
                    .toggleStyle(.switch)
                    .help("Disabled sources stay in the scene but are left out of the solve (⇧⌘D)")
                Picker("Kind", selection: model.sourceBinding(id, "Change Source Kind", \.kind, fallback: .gaussianBeam)) {
                    ForEach(SourceKind.allCases) { Text(Self.shortTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Switching keeps the amplitude, phase, angle and position")
                // An emitter's placement problems sit under its position instead.
                IssueLines(issues: (source.kind == .lineSource ? [] : model.sourceIssues(index, key: nil)) + model.sourceIssues(index, key: "id"))
            } header: {
                Label(source.kind.title, systemImage: source.kind.symbol)
            }

            switch source.kind {
            case .gaussianBeam:
                Section("Beam") {
                    LengthField(
                        title: "Waist Radius $w_0$",
                        value: model.sourceBinding(id, "Change Waist Radius", \.waistUm, fallback: 3),
                        lambda: lambda,
                        range: 0.1 * lambda...max(10 * lambda, min(domain.width, domain.height) / 2),
                        limits: 0.01...1e4,
                        issues: model.sourceIssues(index, key: "waist_um"),
                        onEditingChanged: model.editingChanged("Change Waist Radius")
                    )
                    position(index, xTitle: "Waist $x$", yTitle: "Waist $y$", xKey: "waist_x_um", yKey: "waist_y_um", name: "Move Waist")
                    angleRow(index)
                }
            case .planeWave:
                Section("Plane Wave") {
                    angleRow(index)
                }
            case .lineSource:
                Section {
                    position(index, xTitle: "Position $x$", yTitle: "Position $y$", xKey: "x_um", yKey: "y_um", name: "Move Source")
                    IssueLines(issues: model.sourceIssues(index, key: nil))
                } header: {
                    Text("Emitter")
                } footer: {
                    MathText.footer(#"An $E_z$ line current: a point in the plane radiating cylindrical waves. $|E|$ is about $A$ one background wavelength away. Keep it 0.1 $\lambda_b$ from every body."#)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ValueRow(
                    title: "Amplitude $A$",
                    value: model.sourceBinding(id, "Change Amplitude", \.amplitude, fallback: 1),
                    range: 0.1...5,
                    limits: 1e-6...1e6,
                    digits: 2,
                    neutral: 1,
                    onEditingChanged: model.editingChanged("Change Amplitude")
                )
                IssueLines(issues: model.sourceIssues(index, key: "amplitude"))
                ValueRow(
                    title: #"Phase $\varphi$"#,
                    value: model.sourceBinding(id, "Change Source Phase", \.phaseDeg, fallback: 0),
                    range: 0...360,
                    limits: -360...720,
                    unit: "°",
                    digits: 0,
                    onEditingChanged: model.editingChanged("Change Source Phase")
                )
                IssueLines(issues: model.sourceIssues(index, key: "phase_deg"))
            } header: {
                Text("Strength")
            } footer: {
                Text(scene.sources.count > 1
                     ? "Sources are coherent: the field is the sum of all enabled sources."
                     : "Defined in the background as if no elements were present.")
                    .foregroundStyle(.secondary)
            }

            if source.kind == .gaussianBeam, let derived = model.checkReport?.derived?.source(id),
               derived.rayleighRangeUm != nil || derived.divergenceDeg != nil {
                Section {
                    if let zR = derived.rayleighRangeUm {
                        LabeledContent { Text(Format.micrometres(zR)) } label: { MathText("Rayleigh Range $z_R$") }
                    }
                    if let theta = derived.divergenceDeg {
                        LabeledContent { Text(Format.degrees(theta, digits: 2)) } label: { MathText(#"Divergence $\theta_0$"#) }
                    }
                } header: {
                    Text("Derived")
                } footer: {
                    Text("Paraxial estimates, not solver output.")
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }

            Section {
                Button("Duplicate Source") { model.duplicate(.source(id)) }
                    .help("Add a copy of this source (⌘D)")
                Button("Delete Source", role: .destructive) { model.delete(.source(id)) }
                    .help("Remove this source from the scene; ⌫ in the sidebar does the same")
            }
        }
    }

    /// Segment titles short enough for three in the inspector.
    static func shortTitle(_ kind: SourceKind) -> String {
        switch kind {
        case .gaussianBeam: return "Gaussian Beam"
        case .planeWave: return "Plane Wave"
        case .lineSource: return "Emitter"
        }
    }

    @ViewBuilder
    private func position(_ index: Int, xTitle: String, yTitle: String, xKey: String, yKey: String, name: String) -> some View {
        let domain = model.scene.domain
        let lambda = model.scene.lambdaB
        let xIssues = model.sourceIssues(index, key: xKey)
        let yIssues = model.sourceIssues(index, key: yKey)
        LiveFields {
            LengthField(
                title: xTitle,
                value: model.sourceBinding(id, name, \.xUm, fallback: 0, live: true),
                lambda: lambda,
                range: domain.xMinUm...domain.xMaxUm,
                issues: xIssues,
                onEditingChanged: model.editingChanged(name)
            )
            LengthField(
                title: yTitle,
                value: model.sourceBinding(id, name, \.yUm, fallback: 0, live: true),
                lambda: lambda,
                range: domain.yMinUm...domain.yMaxUm,
                issues: yIssues,
                onEditingChanged: model.editingChanged(name)
            )
        }
    }

    private func angleRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LiveFields {
                ValueRow(
                    title: "Angle",
                    value: model.sourceBinding(id, "Change Beam Angle", \.angleDeg, fallback: 0, live: true),
                    range: -90...90,
                    limits: -360...360,
                    unit: "°",
                    digits: 1,
                    neutral: 0,
                    onEditingChanged: model.editingChanged("Change Beam Angle")
                )
            }
            IssueLines(issues: model.sourceIssues(index, key: "angle_deg"))
        }
    }
}
