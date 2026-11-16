import SwiftUI

struct SimulationForm: View {
    let model: AppState

    var body: some View {
        let scene = model.scene
        let method = scene.solver.method
        let domain = scene.domain
        let lambda = scene.lambdaB

        Section {
            Picker("Solver", selection: Binding(get: { method }, set: { model.setMethod($0) })) {
                ForEach(SolverMethod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(method.explainer)
                .font(.callout)
                .foregroundStyle(.secondary)
            IssueLines(issues: model.checkReport?.issues(withPrefix: "solver").filter { $0.path == "solver" || $0.path == "solver.\(method.rawValue)" } ?? [])
        } header: {
            Text("Solver")
        }

        Section {
            LengthField(
                title: "Center x",
                value: Binding(get: { domain.centerX }, set: { model.setDomainCenter(x: $0) }),
                lambda: lambda
            )
            LengthField(
                title: "Center y",
                value: Binding(get: { domain.centerY }, set: { model.setDomainCenter(y: $0) }),
                lambda: lambda
            )
            LengthField(
                title: "Width",
                value: Binding(get: { domain.width }, set: { model.setDomainWidth($0) }),
                lambda: lambda,
                limits: 2 * lambda...400 * lambda
            )
            LabeledContent("Height") {
                Text(Format.micrometres(domain.height))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            IssueLines(issues: model.checkReport?.issues(withPrefix: "domain").filter { $0.path != "domain.pml_wl" } ?? [])
            Button("Fit Domain to Elements") { model.fitDomainToElements() }
        } header: {
            Text("Domain")
        } footer: {
            Text("The image shows the domain. Its height follows the output aspect ratio (\(model.output.aspect.title)).")
                .foregroundStyle(.secondary)
        }

        Section {
            ValueRow(
                title: "PML Thickness",
                value: model.binding("Change PML Thickness", \.scene.domain.pmlWl),
                range: 0.5...4,
                limits: 0.5...4,
                unit: "λ",
                digits: 2,
                onEditingChanged: model.editingChanged("Change PML Thickness")
            )
            .disabled(method == .mom)
            IssueLines(issues: model.issues(at: "domain.pml_wl"))
        } header: {
            Text("Absorbing Layer")
        } footer: {
            Text(method == .mom
                 ? "MoM needs no PML: its boundary integrals radiate exactly."
                 : "A perfectly matched layer around the domain absorbs outgoing waves.")
                .foregroundStyle(.secondary)
        }

        EstimateSection(model: model)

        AdvancedSection(model: model, method: method)

        ResultSection(model: model)
    }
}

private struct EstimateSection: View {
    let model: AppState

    var body: some View {
        let estimates = model.checkReport?.estimates
        Section("Estimates") {
            row("Preview", estimates?.preview, quality: .preview)
            row("Final", estimates?.final, quality: .final)
            if let tooLarge = model.solver.finalTooLarge {
                IssueLines(issues: [tooLarge])
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func row(_ title: String, _ estimate: EstimateReport?, quality: QualityName) -> some View {
        if let estimate {
            LabeledContent(title) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("≈ \(estimate.summary) · \(SceneFormat.megabytes(estimate.memoryMb))")
                    Text("\(SceneFormat.fixed(estimate.ppw, 0)) \(estimate.method.ppwNoun) per λ · \(estimate.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent(title, value: "—")
        }
    }
}

private struct AdvancedSection: View {
    let model: AppState
    let method: SolverMethod

    @UIState private var isExpanded = false

    var body: some View {
        let settings = model.scene.solver
        Section {
            DisclosureGroup("Advanced \(method.title) Settings", isExpanded: $isExpanded) {
                switch method {
                case .fdtd:
                    ppwFields(\.scene.solver.fdtd.previewPpw, \.scene.solver.fdtd.finalPpw)
                    ValueRow(
                        title: "Courant Number",
                        value: model.binding("Change Courant Number", \.scene.solver.fdtd.courant),
                        range: 0.1...0.65,
                        limits: 0.1...0.65,
                        digits: 2,
                        onEditingChanged: model.editingChanged("Change Courant Number")
                    )
                    OptionalNumberField(
                        title: "Maximum Periods",
                        value: Binding(
                            get: { settings.fdtd.maxPeriods.map(Double.init) },
                            set: { v in model.edit("Change Maximum Periods") { $0.scene.solver.fdtd.maxPeriods = v.map { Int($0.rounded()) } } }
                        ),
                        placeholder: "Automatic",
                        limits: 1...100_000
                    )
                    OptionalNumberField(
                        title: "Steady-State Tolerance",
                        value: model.binding("Change Steady-State Tolerance", \.scene.solver.fdtd.steadyTol),
                        placeholder: "Default",
                        limits: 1e-9...0.5
                    )
                    Toggle("Subpixel smoothing", isOn: model.binding("Change Subpixel Smoothing", \.scene.solver.fdtd.subpixel))
                    Toggle("Dispersion correction", isOn: model.binding("Change Dispersion Correction", \.scene.solver.fdtd.dispersionCorrection))
                case .fem:
                    ppwFields(\.scene.solver.fem.previewPpw, \.scene.solver.fem.finalPpw)
                    Picker("Element Order", selection: model.binding("Change Element Order", \.scene.solver.fem.order)) {
                        Text("P2").tag(2)
                        Text("P3").tag(3)
                    }
                    .pickerStyle(.segmented)
                    OptionalNumberField(
                        title: "PML Reflection",
                        value: Binding(
                            get: { settings.fem.pmlReflection },
                            set: { v in model.edit("Change PML Reflection") { $0.scene.solver.fem.pmlReflection = v ?? 1e-6 } }
                        ),
                        placeholder: "1e-6",
                        limits: 1e-12...1e-2
                    )
                case .mom:
                    ppwFields(\.scene.solver.mom.previewPpw, \.scene.solver.mom.finalPpw)
                    Picker("PEC Formulation", selection: model.binding("Change PEC Formulation", \.scene.solver.mom.pecFormulation)) {
                        ForEach(PecFormulation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    ValueRow(
                        title: "CFIE β Scale",
                        value: model.binding("Change CFIE Scale", \.scene.solver.mom.cfieBetaScale),
                        range: 0.1...4,
                        limits: 0.01...10,
                        digits: 2,
                        neutral: 1,
                        onEditingChanged: model.editingChanged("Change CFIE Scale")
                    )
                    Toggle("Grade panels at corners", isOn: model.binding("Change Corner Grading", \.scene.solver.mom.cornerGrading))
                }
                if method != .fdtd {
                    OptionalNumberField(
                        title: "Preview Output Samples",
                        value: model.binding("Change Output Sampling", \.scene.solver.output.previewPpw),
                        placeholder: "6",
                        unit: "/λ",
                        limits: 4...80
                    )
                    OptionalNumberField(
                        title: "Final Output Samples",
                        value: model.binding("Change Output Sampling", \.scene.solver.output.finalPpw),
                        placeholder: "12",
                        unit: "/λ",
                        limits: 4...80
                    )
                }
                OptionalNumberField(
                    title: "Memory Limit",
                    value: model.binding("Change Memory Limit", \.scene.solver.memoryLimitMb),
                    placeholder: "Default",
                    unit: "MB",
                    limits: 16...262_144
                )
                IssueLines(issues: model.checkReport?.issues(withPrefix: "solver").filter {
                    $0.path != "solver" && $0.path != "solver.\(method.rawValue)" && $0.code != "too_large"
                } ?? [])
            }
        } footer: {
            Text("Leave a field empty for the default. Resolution counts \(method.ppwNoun) per wavelength in the densest material.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func ppwFields(_ preview: WritableKeyPath<FringeDocument, Double?>, _ final: WritableKeyPath<FringeDocument, Double?>) -> some View {
        OptionalNumberField(
            title: "Preview Resolution",
            value: model.binding("Change Resolution", preview),
            placeholder: SceneFormat.fixed(method.defaultPPW(final: false), 0),
            unit: "/λ",
            limits: 4...80
        )
        OptionalNumberField(
            title: "Final Resolution",
            value: model.binding("Change Resolution", final),
            placeholder: SceneFormat.fixed(method.defaultPPW(final: true), 0),
            unit: "/λ",
            limits: 4...80
        )
    }
}

private struct ResultSection: View {
    let model: AppState

    var body: some View {
        if let shown = model.solver.shown {
            let meta = shown.info.meta
            Section("Last Result") {
                LabeledContent("Status", value: model.solver.status.title)
                LabeledContent("Solver", value: "\(meta.method.title) · \(meta.quality.title) · \(SceneFormat.fixed(meta.ppw, 0))/λ")
                LabeledContent(meta.method.unknownsNoun.capitalizedFirst, value: SceneFormat.count(meta.unknowns))
                if let periods = meta.periods {
                    LabeledContent("Periods", value: SceneFormat.fixed(periods, 0))
                }
                LabeledContent("Converged", value: meta.converged ? "Yes" : "No")
                if let residual = meta.residual {
                    LabeledContent("Residual", value: String(format: "%.1e", residual))
                }
                if let cond = meta.condEstimate {
                    LabeledContent("Condition Estimate", value: String(format: "%.1e", cond))
                }
                LabeledContent("Time", value: SceneFormat.seconds(meta.wallS))
                LabeledContent("Grid", value: "\(shown.info.grid.nx) × \(shown.info.grid.ny)")
                ForEach(meta.warnings, id: \.self) { warning in
                    Label(warning.prefix(1).uppercased() + warning.dropFirst(), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .monospacedDigit()
        }
    }
}

extension String {
    /// "cells" → "Cells", "DOFs" stays.
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
